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
    server_set_name: str,
    logical_session_timeout_minutes: int,
}

struct OpMessage {
    request_id: int,
    response_to: int,
    body: Document,
}

struct OpFrame {
    request_id: int,
    header: bytes,
    tail: bytes,
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
    let frame_result = mongo_command_exchange_locked(c, database, body,
                                                      deadline);
    guard let frame = frame_result else let e = err_of(frame_result) {
        return err(e);
    }
    let full = builder.new_bytes();
    full.write(frame.header);
    full.write(frame.tail);
    let response_raw = full.finish();
    let decoded = mongo_decode_op_msg(response_raw, frame.request_id, c.config);
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

fn mongo_command_view_on(c: Conn, database: str, body: Document,
                         deadline: until) -> result[DocumentView, str] {
    mutex_lock(c.lock);
    let view_result = mongo_command_view_locked(c, database, body, deadline);
    mutex_unlock(c.lock);
    return view_result;
}

fn mongo_command_view_locked(c: Conn, database: str, body: Document,
                             deadline: until)
                            -> result[DocumentView, str] {
    let frame_result = mongo_command_exchange_locked(c, database, body,
                                                      deadline);
    guard let frame = frame_result else let e = err_of(frame_result) {
        return err(e);
    }
    let decoded = mongo_decode_op_msg_view(frame.header, frame.tail,
                                           frame.request_id, c.config);
    guard let response = decoded else let e = err_of(decoded) {
        mongo_break_connection(c);
        return err(e);
    }
    let status = mongo_check_command_status_view(response);
    guard let _ok = status else let e = err_of(status) {
        if strings.has_prefix(e, "mongo.command protocol:") {
            mongo_break_connection(c);
        }
        return err(e);
    }
    return ok(response);
}

fn mongo_command_exchange_locked(c: Conn, database: str, body: Document,
                                 deadline: until) -> result[OpFrame, str] {
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
    return ok(OpFrame {
        request_id: request_id,
        header: header_bytes,
        tail: tail
    });
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

fn mongo_decode_op_msg_view(header: bytes, tail: bytes,
                            expected_response_to: int, config: Config)
                           -> result[DocumentView, str] {
    if len(header) != 16 || len(tail) < 5 ||
       len(header) + len(tail) > config.max_message_bytes {
        return err("mongo.command protocol: response size is outside configured bounds");
    }
    let message_length = mongo_wire_read_i32(header, 0);
    if message_length != len(header) + len(tail) {
        return err("mongo.command protocol: declared message length does not match received bytes");
    }
    if mongo_wire_read_i32(header, 12) != OP_MSG {
        return err("mongo.command protocol: expected OP_MSG response");
    }
    if mongo_wire_read_i32(header, 8) != expected_response_to {
        return err("mongo.command protocol: responseTo does not match request id");
    }
    if mongo_wire_read_i32(tail, 0) != 0 {
        return err("mongo.command protocol: unsupported OP_MSG flags");
    }
    if tail[4] != 0 {
        return err("mongo.command protocol: only a single body section is supported");
    }
    let bson_length = mongo_wire_read_i32(tail, 5);
    if bson_length < 5 || bson_length > config.max_bson_bytes ||
       bson_length != len(tail) - 5 {
        return err("mongo.command protocol: invalid or oversized BSON body length");
    }
    let bounds = new_limits(config.max_bson_bytes, DEFAULT_MAX_BSON_DEPTH,
                            DEFAULT_MAX_BSON_VALUES);
    guard let limits = bounds else let e = err_of(bounds) {
        return err("mongo.command protocol: invalid BSON limit: " + e);
    }
    return bson_view_decode_at(tail, 5, bson_length, limits);
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
    if let error_value = details {
        let error_text = as_string(error_value);
        guard let text = error_text else {
            return err("mongo.command protocol: errmsg is not a string");
        }
        message = text;
        if len(message) > 1024 {
            message = strings.slice(message, 0, 1024);
        }
    }
    let code_text = "";
    let code_field = get(body, "code");
    if let code_value = code_field {
        if code_value.kind == BSON_INT32 || code_value.kind == BSON_INT64 {
            code_text = " [" + to_str(code_value.int_value) + "]";
        }
    }
    let labels = mongo_command_error_labels(body);
    guard let label_text = labels else let e = err_of(labels) { return err(e); }
    return err("mongo command failed" + code_text + label_text + ": " + message);
}

fn mongo_check_command_status_view(body: DocumentView)
                                   -> result[bool, str] {
    let found = view_get(body, "ok");
    guard let status_opt = found else let e = err_of(found) { return err(e); }
    guard let status = status_opt else {
        return err("mongo.command protocol: response has no ok field");
    }
    let successful = false;
    if view_kind(status) == BSON_DOUBLE {
        let number_result = view_as_double(status);
        guard let number = number_result else let e = err_of(number_result) {
            return err("mongo.command protocol: invalid ok field: " + e);
        }
        successful = number != 0.0;
    } else if view_kind(status) == BSON_INT32 || view_kind(status) == BSON_INT64 {
        let number_result = view_as_int(status);
        guard let number = number_result else let e = err_of(number_result) {
            return err("mongo.command protocol: invalid ok field: " + e);
        }
        successful = number != 0;
    } else {
        return err("mongo.command protocol: response ok field is not numeric");
    }
    if successful {
        return ok(true);
    }

    let message = "command failed";
    let details = view_get(body, "errmsg");
    guard let details_opt = details else let e = err_of(details) { return err(e); }
    if let error_value = details_opt {
        let error_text = view_as_string(error_value);
        guard let text = error_text else {
            return err("mongo.command protocol: errmsg is not a string");
        }
        message = text;
        if len(message) > 1024 {
            message = strings.slice(message, 0, 1024);
        }
    }
    let code_text = "";
    let code_field = view_get(body, "code");
    guard let code_opt = code_field else let e = err_of(code_field) { return err(e); }
    if let code_value = code_opt {
        if view_kind(code_value) == BSON_INT32 ||
           view_kind(code_value) == BSON_INT64 {
            let code_result = view_as_int(code_value);
            guard let code = code_result else let e = err_of(code_result) {
                return err("mongo.command protocol: invalid code: " + e);
            }
            code_text = " [" + to_str(code) + "]";
        }
    }
    let labels = mongo_command_error_labels_view(body);
    guard let label_text = labels else let e = err_of(labels) { return err(e); }
    return err("mongo command failed" + code_text + label_text + ": " + message);
}

fn mongo_command_error_labels_view(body: DocumentView) -> result[str, str] {
    let field = view_get(body, "errorLabels");
    guard let value_opt = field else let e = err_of(field) { return err(e); }
    guard let value = value_opt else { return ok(""); }
    if view_kind(value) != BSON_ARRAY {
        return err("mongo.command protocol: errorLabels is not an array");
    }
    let raw = bson_value_view_raw(value);
    let pos = bson_value_view_start(value) + 4;
    let end = bson_value_view_end(value) - 1;
    let out = "";
    let index = 0;
    while pos < end {
        if index >= 16 {
            return err("mongo.command protocol: too many error labels");
        }
        if raw[pos] != BSON_STRING {
            return err("mongo.command protocol: error label is not a string");
        }
        let key_end_result = bson_view_cstring_end(raw, pos + 1, end);
        guard let key_end = key_end_result else let e = err_of(key_end_result) {
            return err("mongo.command protocol: invalid error label index: " + e);
        }
        if !bson_view_index_matches(raw, pos + 1, key_end, index) {
            return err("mongo.command protocol: error label array index is invalid");
        }
        let value_start = key_end + 1;
        let value_end_result = bson_view_value_end(raw, value_start, end,
                                                    BSON_STRING);
        guard let value_end = value_end_result else let e = err_of(value_end_result) {
            return err("mongo.command protocol: invalid error label: " + e);
        }
        let label_result = view_as_string(
            bson_view_make_value(raw, BSON_STRING, value_start, value_end));
        guard let label = label_result else let e = err_of(label_result) {
            return err("mongo.command protocol: invalid error label: " + e);
        }
        if label == "" || len(label) > 64 {
            return err("mongo.command protocol: error label length is invalid");
        }
        if index == 0 {
            out = " [errorLabels=" + label;
        } else {
            out = out + "," + label;
        }
        pos = value_end;
        index = index + 1;
    }
    if index > 0 {
        out = out + "]";
    }
    return ok(out);
}

fn mongo_command_error_labels(body: Document) -> result[str, str] {
    let field = get(body, "errorLabels");
    guard let value = field else { return ok(""); }
    let decoded = as_array(value);
    guard let labels = decoded else {
        return err("mongo.command protocol: errorLabels is not an array");
    }
    if len(labels) > 16 {
        return err("mongo.command protocol: too many error labels");
    }
    let out = "";
    let i = 0;
    while i < len(labels) {
        let label_result = as_string(labels[i]);
        guard let label = label_result else let e = err_of(label_result) {
            return err("mongo.command protocol: invalid error label: " + e);
        }
        if label == "" || len(label) > 64 {
            return err("mongo.command protocol: error label length is invalid");
        }
        if i == 0 {
            out = " [errorLabels=" + label;
        } else {
            out = out + "," + label;
        }
        i = i + 1;
    }
    if len(labels) > 0 {
        out = out + "]";
    }
    return ok(out);
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
