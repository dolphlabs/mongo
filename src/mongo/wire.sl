import "net";
import "builder";
import "strings";

pub let OP_MSG = 2013;

pub gc struct Conn {
    config: Config,
    fd: i32,
    ssl: rawptr,
    tls: bool,
    next_request_id: int,
    lock: mutex,
    closed: bool,
    broken: bool,
    pool_managed: bool,
    pool_checked_out: bool,
    server_max_wire_version: int,
    is_writable_primary: bool,
}

struct OpMessage {
    request_id: int,
    response_to: int,
    body: Document,
}

pub fn usable(c: Conn) -> bool {
    return !c.closed && !c.broken;
}

pub fn close_conn(c: Conn) {
    mutex_lock(c.lock);
    mongo_close_transport(c);
    mutex_unlock(c.lock);
}

pub fn command(c: Conn, body: Document, deadline: until)
               -> result[Document, str] {
    return command_on(c, c.config.database, body, deadline);
}

pub fn command_on(c: Conn, database: str, body: Document, deadline: until)
                  -> result[Document, str] {
    mutex_lock(c.lock);
    let command_result = mongo_command_locked(c, database, body, deadline);
    mutex_unlock(c.lock);
    return command_result;
}

fn mongo_command_locked(c: Conn, database: str, body: Document,
                        deadline: until) -> result[Document, str] {
    if c.closed || c.broken {
        return err("mongo.command: connection is closed or broken");
    }
    if c.pool_managed && !c.pool_checked_out {
        return err("mongo.command: pooled connection is not checked out");
    }
    if database == "" {
        return err("mongo.command: database cannot be empty");
    }
    let prepared = mongo_add_database(body, database);
    guard let command_body = prepared else let e = err_of(prepared) {
        return err(e);
    }
    let request_id = c.next_request_id;
    c.next_request_id = c.next_request_id + 1;
    if c.next_request_id > 2147483647 {
        c.next_request_id = 1;
    }
    let encoded = mongo_encode_op_msg(request_id, command_body, c.config);
    guard let request = encoded else let e = err_of(encoded) {
        return err(e);
    }
    let sent = mongo_transport_send(c, request, deadline);
    guard let count = sent else let e = err_of(sent) {
        mongo_break_connection(c);
        return err("mongo.command: send failed: " + e);
    }
    if count != len(request) {
        mongo_break_connection(c);
        return err("mongo.command: partial message write; connection closed");
    }

    let header = mongo_transport_read(c, 16, deadline);
    guard let header_bytes = header else let e = err_of(header) {
        mongo_break_connection(c);
        return err("mongo.command: response header read failed: " + e);
    }
    let message_length = mongo_wire_read_i32(header_bytes, 0);
    if message_length < 21 || message_length > c.config.max_message_bytes {
        mongo_break_connection(c);
        return err("mongo.command: invalid response message length");
    }
    let remainder = mongo_transport_read(c, message_length - 16, deadline);
    guard let tail = remainder else let e = err_of(remainder) {
        mongo_break_connection(c);
        return err("mongo.command: response body read failed: " + e);
    }
    let full = builder.new_bytes();
    full.write(header_bytes);
    full.write(tail);
    let response_raw = full.finish();
    let decoded = mongo_decode_op_msg(response_raw, request_id, c.config);
    guard let response = decoded else let e = err_of(decoded) {
        mongo_break_connection(c);
        return err(e);
    }
    let status = mongo_check_command_status(response.body);
    guard let _ok = status else let e = err_of(status) {
        if strings.has_prefix(e, "mongo.command protocol:") {
            mongo_break_connection(c);
        }
        return err(e);
    }
    return ok(response.body);
}

fn mongo_add_database(source: Document, database: str)
                      -> result[Document, str] {
    let out = document();
    let i = 0;
    while i < len(source.fields) {
        let field = source.fields[i];
        if field.key != "$db" {
            let inserted = put(out, field.key, field.value);
            guard let _ok = inserted else let e = err_of(inserted) {
                return err("mongo.command: " + e);
            }
        }
        i = i + 1;
    }
    let db_value = string_value(database);
    let inserted = put(out, "$db", db_value);
    guard let _ok = inserted else let e = err_of(inserted) {
        return err("mongo.command: " + e);
    }
    return ok(out);
}

fn mongo_encode_op_msg(request_id: int, body: Document, config: Config)
                      -> result[bytes, str] {
    let bounds = new_limits(config.max_bson_bytes, DEFAULT_MAX_BSON_DEPTH,
                            DEFAULT_MAX_BSON_VALUES);
    guard let limits = bounds else let e = err_of(bounds) {
        return err("mongo.command: invalid BSON limit: " + e);
    }
    let encoded = encode_with_limits(body, limits);
    guard let bson = encoded else let e = err_of(encoded) {
        return err("mongo.command: BSON encode failed: " + e);
    }
    let message_length = 21 + len(bson);
    if message_length > config.max_message_bytes ||
       message_length > 2147483647 {
        return err("mongo.command: request exceeds configured message limit");
    }
    let out = builder.new_bytes();
    out.write(to_le(message_length)[0..4]);
    out.write(to_le(request_id)[0..4]);
    out.write(to_le(0)[0..4]);
    out.write(to_le(OP_MSG)[0..4]);
    out.write(to_le(0)[0..4]);
    out.write_byte(0);
    out.write(bson);
    return ok(out.finish());
}

fn mongo_decode_op_msg(raw: bytes, expected_response_to: int, config: Config)
                      -> result[OpMessage, str] {
    if len(raw) < 21 || len(raw) > config.max_message_bytes {
        return err("mongo.command protocol: response size is outside configured bounds");
    }
    let message_length = mongo_wire_read_i32(raw, 0);
    if message_length != len(raw) {
        return err("mongo.command protocol: declared message length does not match received bytes");
    }
    let request_id = mongo_wire_read_i32(raw, 4);
    let response_to = mongo_wire_read_i32(raw, 8);
    let opcode = mongo_wire_read_i32(raw, 12);
    if opcode != OP_MSG {
        return err("mongo.command protocol: expected OP_MSG response");
    }
    if response_to != expected_response_to {
        return err("mongo.command protocol: responseTo does not match request id");
    }
    let flags = mongo_wire_read_i32(raw, 16);
    if flags != 0 {
        return err("mongo.command protocol: unsupported OP_MSG flags");
    }
    if raw[20] != 0 {
        return err("mongo.command protocol: only a single body section is supported");
    }
    let bson_length = mongo_wire_read_i32(raw, 21);
    if bson_length < 5 || bson_length > config.max_bson_bytes ||
       bson_length != len(raw) - 21 {
        return err("mongo.command protocol: invalid or oversized BSON body length");
    }
    let bounds = new_limits(config.max_bson_bytes, DEFAULT_MAX_BSON_DEPTH,
                            DEFAULT_MAX_BSON_VALUES);
    guard let limits = bounds else let e = err_of(bounds) {
        return err("mongo.command protocol: invalid BSON limit: " + e);
    }
    let decoded = decode_with_limits(raw[21..], limits);
    guard let body = decoded else let e = err_of(decoded) {
        return err("mongo.command protocol: invalid BSON response: " + e);
    }
    return ok(OpMessage {
        request_id: request_id,
        response_to: response_to,
        body: body
    });
}

fn mongo_check_command_status(body: Document) -> result[bool, str] {
    let found = get(body, "ok");
    guard let status = found else {
        return err("mongo.command protocol: response has no ok field");
    }
    let successful = false;
    if status.kind == BSON_DOUBLE {
        successful = status.float_value != 0.0;
    } else if status.kind == BSON_INT32 || status.kind == BSON_INT64 {
        successful = status.int_value != 0;
    } else {
        return err("mongo.command protocol: response ok field is not numeric");
    }
    if successful {
        return ok(true);
    }
    let message = "command failed";
    let details = get(body, "errmsg");
    guard let error_value = details else {
        return err("mongo command failed: " + message);
    }
    let error_text = as_string(error_value);
    guard let text = error_text else {
        return err("mongo.command protocol: errmsg is not a string");
    }
    message = text;
    if len(message) > 1024 {
        message = strings.slice(message, 0, 1024);
    }
    let code_text = "";
    let code_field = get(body, "code");
    guard let code_value = code_field else {
        return err("mongo command failed: " + message);
    }
    if code_value.kind == BSON_INT32 || code_value.kind == BSON_INT64 {
        code_text = " [" + to_str(code_value.int_value) + "]";
    }
    return err("mongo command failed" + code_text + ": " + message);
}

fn mongo_transport_send(c: Conn, payload: bytes, deadline: until)
                       -> result[int, str] {
    if c.tls {
        let sent = net.tls_send_until(c.ssl, payload, deadline);
        guard let n = sent else let e = err_of(sent) { return err(e); }
        return ok(n as int);
    }
    let sent = net.send_until(c.fd, payload, deadline);
    guard let n = sent else let e = err_of(sent) { return err(e); }
    return ok(n as int);
}

fn mongo_transport_read(c: Conn, wanted: int, deadline: until)
                       -> result[bytes, str] {
    if wanted < 0 || wanted > c.config.max_message_bytes {
        return err("requested read exceeds configured message limit");
    }
    let output = builder.new_bytes();
    while output.size() < wanted {
        let remaining = wanted - output.size();
        let received: opt[bytes] = none;
        if c.tls {
            let r = net.tls_recv_until(c.ssl, remaining, deadline);
            guard let chunk = r else let e = err_of(r) { return err(e); }
            received = some(chunk);
        } else {
            let r = net.recv_until(c.fd, remaining, deadline);
            guard let chunk = r else let e = err_of(r) { return err(e); }
            received = some(chunk);
        }
        guard let part = received else {
            return err("internal missing transport read");
        }
        if len(part) == 0 {
            return err("peer closed the connection");
        }
        if len(part) > remaining {
            return err("transport returned more bytes than requested");
        }
        output.write(part);
    }
    return ok(output.finish());
}

fn mongo_break_connection(c: Conn) {
    c.broken = true;
    mongo_close_transport(c);
}

fn mongo_close_transport(c: Conn) {
    if c.closed {
        return;
    }
    if c.tls {
        net.tls_close(c.ssl);
    } else {
        net.close(c.fd);
    }
    c.closed = true;
}

fn mongo_wire_read_i32(raw: bytes, pos: int) -> int {
    if pos < 0 || pos > len(raw) - 4 {
        return -1;
    }
    let value = raw[pos] + raw[pos + 1] * 256 +
                raw[pos + 2] * 65536 + raw[pos + 3] * 16777216;
    if raw[pos + 3] >= 128 {
        return value - 4294967296;
    }
    return value;
}
