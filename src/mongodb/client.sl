import "net";
import "crypto";
import "encoding";
import "strings";

pub fn connect(uri: str, deadline: until) -> result[Conn, str] {
    let parsed = parse_uri(uri);
    guard let cfg = parsed else let e = err_of(parsed) {
        return err(e);
    }
    return connect_config(cfg, deadline);
}

pub fn connect_config(cfg: Config, deadline: until) -> result[Conn, str] {
    if !mongo_host_valid(cfg.host) || cfg.port < 1 || cfg.port > 65535 {
        return err("mongodb.connect: invalid host or port");
    }
    if cfg.database == "" || cfg.auth_source == "" {
        return err("mongodb.connect: database and auth source cannot be empty");
    }
    if cfg.max_bson_bytes < 5 || cfg.max_bson_bytes > DEFAULT_MAX_BSON_BYTES {
        return err("mongodb.connect: BSON limit must be between 5 and 16777216 bytes");
    }
    if cfg.max_message_bytes < 21 ||
       cfg.max_message_bytes > DEFAULT_MAX_MESSAGE_BYTES {
        return err("mongodb.connect: message limit must be between 21 and 50331648 bytes");
    }
    if cfg.auth_mechanism != "SCRAM-SHA-256" {
        return err("mongodb.connect: only SCRAM-SHA-256 authentication is supported");
    }
    if cfg.username != "" &&
       (!mongo_scram_ascii(cfg.username) || !mongo_scram_ascii(cfg.password)) {
        return err("mongodb.connect: SCRAM-SHA-256 currently requires printable ASCII credentials");
    }
    let dialed = net.dial_until(cfg.host, cfg.port, deadline);
    guard let fd = dialed else let e = err_of(dialed) {
        return err("mongodb.connect: dial failed: " + e);
    }
    let ssl: rawptr = nullptr;
    if cfg.tls {
        if cfg.tls_context == nullptr {
            let context = net.tls_client_ctx(cfg.ca_file);
            guard let ctx = context else let e = err_of(context) {
                net.close(fd);
                return err("mongodb.connect: TLS context failed: " + e);
            }
            cfg.tls_context = ctx;
        }
        let upgraded = net.tls_upgrade_until(fd, cfg.host, cfg.tls_context,
                                             deadline);
        guard let connected_ssl = upgraded else let e = err_of(upgraded) {
            net.close(fd);
            return err("mongodb.connect: TLS handshake failed: " + e);
        }
        ssl = connected_ssl;
    }
    let connection = Conn {
        config: cfg,
        fd: fd,
        ssl: ssl,
        tls: cfg.tls,
        next_request_id: 1,
        lock: make_mutex(),
        closed: false,
        broken: false,
        server_max_wire_version: 0
    };
    let hello = mongo_handshake(connection, deadline);
    guard let _hello = hello else let e = err_of(hello) {
        close_conn(connection);
        return err(e);
    }
    if cfg.username != "" {
        let authenticated = mongo_scram_authenticate(connection, deadline);
        guard let _auth = authenticated else let e = err_of(authenticated) {
            close_conn(connection);
            return err(e);
        }
    }
    return ok(connection);
}

pub fn server_wire_version(c: Conn) -> int {
    return c.server_max_wire_version;
}

fn mongo_handshake(c: Conn, deadline: until) -> result[bool, str] {
    let hello = document();
    let command_value = int32_value(1);
    guard let hello_command = command_value else let e = err_of(command_value) {
        return err(e);
    }
    let added = put(hello, "hello", hello_command);
    guard let _added = added else let e = err_of(added) { return err(e); }
    let hello_ok = put(hello, "helloOk", bool_value(true));
    guard let _hello_ok = hello_ok else let e = err_of(hello_ok) { return err(e); }
    if c.config.app_name != "" {
        let application = document();
        let name_added = put(application, "name", string_value(c.config.app_name));
        guard let _name = name_added else let e = err_of(name_added) { return err(e); }
        let client = document();
        let application_added = put(client, "application",
                                    document_value(application));
        guard let _application = application_added else let e = err_of(application_added) { return err(e); }
        let client_added = put(hello, "client", document_value(client));
        guard let _client = client_added else let e = err_of(client_added) { return err(e); }
    }
    let response = command_on(c, "admin", hello, deadline);
    let reply = document();
    if let document_reply = response {
        reply = document_reply;
    } else let e = err_of(response) {
        if !strings.contains(e, "mongodb command failed [59]") {
            return err(e);
        }
        let legacy = document();
        let ismaster_value = int32_value(1);
        guard let ismaster_command = ismaster_value else let e = err_of(ismaster_value) {
            return err(e);
        }
        let legacy_added = put(legacy, "isMaster", ismaster_command);
        guard let _legacy = legacy_added else let e = err_of(legacy_added) { return err(e); }
        let hello_ok_added = put(legacy, "helloOk", bool_value(true));
        guard let _legacy_hello = hello_ok_added else let e = err_of(hello_ok_added) { return err(e); }
        let fallback = command_on(c, "admin", legacy, deadline);
        guard let fallback_reply = fallback else let fallback_error = err_of(fallback) {
            return err(fallback_error);
        }
        reply = fallback_reply;
    }
    let wire_field = get(reply, "maxWireVersion");
    guard let wire_value = wire_field else {
        return err("mongodb.connect: server hello omitted maxWireVersion");
    }
    let wire = as_int(wire_value);
    guard let version = wire else let e = err_of(wire) {
        return err("mongodb.connect: invalid maxWireVersion: " + e);
    }
    if version < 6 {
        return err("mongodb.connect: server does not support the OP_MSG protocol");
    }
    c.server_max_wire_version = version;
    let bson_field = get(reply, "maxBsonObjectSize");
    guard let bson_value = bson_field else {
        return err("mongodb.connect: server hello omitted maxBsonObjectSize");
    }
    let bson_size_result = as_int(bson_value);
    guard let server_bson_size = bson_size_result else let e = err_of(bson_size_result) {
        return err("mongodb.connect: invalid maxBsonObjectSize: " + e);
    }
    if server_bson_size < 5 {
        return err("mongodb.connect: server maxBsonObjectSize is invalid");
    }
    if server_bson_size < c.config.max_bson_bytes {
        c.config.max_bson_bytes = server_bson_size;
    }
    let message_field = get(reply, "maxMessageSizeBytes");
    guard let message_value = message_field else {
        return err("mongodb.connect: server hello omitted maxMessageSizeBytes");
    }
    let message_size_result = as_int(message_value);
    guard let server_message_size = message_size_result else let e = err_of(message_size_result) {
        return err("mongodb.connect: invalid maxMessageSizeBytes: " + e);
    }
    if server_message_size < 21 {
        return err("mongodb.connect: server maxMessageSizeBytes is invalid");
    }
    if server_message_size < c.config.max_message_bytes {
        c.config.max_message_bytes = server_message_size;
    }
    return ok(true);
}

fn mongo_scram_authenticate(c: Conn, deadline: until) -> result[bool, str] {
    let random = crypto.rand(24);
    guard let random_bytes = random else let e = err_of(random) {
        return err("mongodb SCRAM: secure nonce generation failed: " + e);
    }
    let client_nonce = encoding.base64_encode(random_bytes);
    let client_first_bare = "n=" + mongo_scram_escape_username(c.config.username) +
                            ",r=" + client_nonce;
    let client_first = "n,," + client_first_bare;
    let first_payload = binary_value(to_bytes(client_first), 0);
    guard let first_binary = first_payload else let e = err_of(first_payload) {
        return err("mongodb SCRAM: " + e);
    }
    let options = document();
    let skip_empty = put(options, "skipEmptyExchange", bool_value(true));
    guard let _skip = skip_empty else let e = err_of(skip_empty) { return err(e); }
    let start = document();
    let start_value = int32_value(1);
    guard let start_command = start_value else let e = err_of(start_value) { return err(e); }
    let a = put(start, "saslStart", start_command);
    guard let _a = a else let e = err_of(a) { return err(e); }
    let b = put(start, "mechanism", string_value(c.config.auth_mechanism));
    guard let _b = b else let e = err_of(b) { return err(e); }
    let d = put(start, "payload", first_binary);
    guard let _d = d else let e = err_of(d) { return err(e); }
    let e = put(start, "autoAuthorize", int64_value(1));
    guard let _e = e else let err_text = err_of(e) { return err(err_text); }
    let f = put(start, "options", document_value(options));
    guard let _f = f else let err_text = err_of(f) { return err(err_text); }
    let started = command_on(c, c.config.auth_source, start, deadline);
    guard let start_reply = started else let err_text = err_of(started) {
        return err("mongodb SCRAM: start failed: " + err_text);
    }
    let conversation_value = mongo_required_field(start_reply, "conversationId");
    guard let conversation_field = conversation_value else let err_text = err_of(conversation_value) {
        return err("mongodb SCRAM: " + err_text);
    }
    let conversation_result = as_int(conversation_field);
    guard let conversation = conversation_result else let err_text = err_of(conversation_result) {
        return err("mongodb SCRAM: invalid conversation id: " + err_text);
    }
    if conversation < 1 || conversation > 2147483647 {
        return err("mongodb SCRAM: invalid conversation id");
    }
    let done_value = mongo_required_field(start_reply, "done");
    guard let done_field = done_value else let err_text = err_of(done_value) {
        return err("mongodb SCRAM: " + err_text);
    }
    let done_result = as_bool(done_field);
    guard let start_done = done_result else let err_text = err_of(done_result) {
        return err("mongodb SCRAM: invalid start completion flag: " + err_text);
    }
    if start_done {
        return err("mongodb SCRAM: server completed authentication without a challenge");
    }
    let first_server_payload = mongo_required_field(start_reply, "payload");
    guard let first_server_value = first_server_payload else let err_text = err_of(first_server_payload) {
        return err("mongodb SCRAM: " + err_text);
    }
    let first_server_binary = as_binary(first_server_value);
    guard let first_server_bytes = first_server_binary else let err_text = err_of(first_server_binary) {
        return err("mongodb SCRAM: invalid server challenge: " + err_text);
    }
    if first_server_value.subtype != 0 {
        return err("mongodb SCRAM: server challenge must use generic binary subtype");
    }
    let server_first_text = mongo_scram_message_from_bytes(first_server_bytes);
    guard let server_first = server_first_text else let err_text = err_of(server_first_text) {
        return err(err_text);
    }
    let proof_result = mongo_scram_client_proof(c.config.username,
                                               c.config.password,
                                               client_nonce,
                                               server_first);
    guard let proof = proof_result else let err_text = err_of(proof_result) {
        return err(err_text);
    }
    let final_binary = binary_value(proof.payload, 0);
    guard let final_value = final_binary else let err_text = err_of(final_binary) {
        return err(err_text);
    }
    let continuation = document();
    let continue_value = int32_value(1);
    guard let continue_command = continue_value else let err_text = err_of(continue_value) { return err(err_text); }
    let c1 = put(continuation, "saslContinue", continue_command);
    guard let _c1 = c1 else let err_text = err_of(c1) { return err(err_text); }
    let conversation_id_result = int32_value(conversation);
    guard let conversation_id = conversation_id_result else let err_text = err_of(conversation_id_result) {
        return err(err_text);
    }
    let c2 = put(continuation, "conversationId", conversation_id);
    guard let _c2 = c2 else let err_text = err_of(c2) { return err(err_text); }
    let c3 = put(continuation, "payload", final_value);
    guard let _c3 = c3 else let err_text = err_of(c3) { return err(err_text); }
    let continued = command_on(c, c.config.auth_source, continuation, deadline);
    guard let final_reply = continued else let err_text = err_of(continued) {
        return err("mongodb SCRAM: continue failed: " + err_text);
    }
    let final_done_value = mongo_required_field(final_reply, "done");
    guard let final_done_field = final_done_value else let err_text = err_of(final_done_value) {
        return err("mongodb SCRAM: " + err_text);
    }
    let final_done_result = as_bool(final_done_field);
    guard let final_done = final_done_result else let err_text = err_of(final_done_result) {
        return err("mongodb SCRAM: invalid final completion flag: " + err_text);
    }
    if !final_done {
        return err("mongodb SCRAM: server did not complete authentication");
    }
    let final_payload_value = mongo_required_field(final_reply, "payload");
    guard let final_payload_field = final_payload_value else let err_text = err_of(final_payload_value) {
        return err("mongodb SCRAM: " + err_text);
    }
    let final_payload_result = as_binary(final_payload_field);
    guard let final_payload = final_payload_result else let err_text = err_of(final_payload_result) {
        return err("mongodb SCRAM: invalid server proof: " + err_text);
    }
    if final_payload_field.subtype != 0 {
        return err("mongodb SCRAM: server proof must use generic binary subtype");
    }
    let server_final_text = mongo_scram_message_from_bytes(final_payload);
    guard let server_final = server_final_text else let err_text = err_of(server_final_text) {
        return err(err_text);
    }
    let verified = mongo_scram_verify_server_final(server_final,
                                                  proof.server_signature);
    guard let _verified = verified else let err_text = err_of(verified) {
        return err(err_text);
    }
    return ok(true);
}

fn mongo_required_field(doc: Document, name: str) -> result[Value, str] {
    let found = get(doc, name);
    guard let value = found else {
        return err("server response omitted " + name);
    }
    return ok(value);
}

fn mongo_scram_verify_server_final(raw: str, expected: bytes)
                                 -> result[bool, str] {
    if len(raw) == 0 || len(raw) > MONGO_SCRAM_MAX_TEXT_BYTES {
        return err("mongodb SCRAM: server-final message has an invalid size");
    }
    let signature = "";
    let seen_signature = false;
    for attribute in strings.split(raw, ",") {
        if strings.has_prefix(attribute, "e=") {
            return err("mongodb SCRAM: server rejected authentication");
        }
        if strings.has_prefix(attribute, "v=") {
            if seen_signature {
                return err("mongodb SCRAM: duplicate server signature");
            }
            seen_signature = true;
            signature = strings.slice(attribute, 2, len(attribute));
        }
    }
    if !seen_signature {
        return err("mongodb SCRAM: server-final message omitted its signature");
    }
    let decoded = encoding.base64_decode(signature);
    guard let server_signature = decoded else {
        return err("mongodb SCRAM: server signature is not valid base64");
    }
    if !mongo_scram_equal_constant_time(expected, server_signature) {
        return err("mongodb SCRAM: server signature verification failed");
    }
    return ok(true);
}
