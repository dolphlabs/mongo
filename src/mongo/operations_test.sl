import "time";
import "net";
import "builder";

fn mongo_operations_test_add(doc: Document, key: str, value: Value) {
    let r = put(doc, key, value);
    guard let _ok = r else let e = err_of(r) { panic(e); }
}

fn test_mongo_find_options_validate_bounds() {
    let options = default_find_options();
    let valid = mongo_validate_find_options(options);
    guard let _valid_options = valid else let e = err_of(valid) { panic(e); }
    options.batch_size = -1;
    let invalid = mongo_validate_find_options(options);
    guard let _ok = invalid else let e = err_of(invalid) {
        assert(strings.contains(e, "non-negative int32"), e);
        return;
    }
    panic("negative batch size was accepted");
}

fn test_mongo_pool_rejects_unbounded_configuration() {
    let config_result = new_config("localhost", 27017, "test");
    guard let cfg = config_result else let e = err_of(config_result) { panic(e); }
    let bad_open = new_pool_config(cfg, 1025);
    guard let _pool = bad_open else let e = err_of(bad_open) {
        assert(strings.contains(e, "max_open"), e);
        let bad_waiters = new_pool_config_with_limits(cfg, 1, 1000001);
        guard let _other_pool = bad_waiters else let waiter_error = err_of(bad_waiters) {
            assert(strings.contains(waiter_error, "max_waiters"), waiter_error);
            return;
        }
        panic("pool accepted more than one million queued waiters");
    }
    panic("pool accepted more than 1,024 open connections");
}

fn test_mongo_cursor_first_batch_values() {
    let empty_batch: [Value] = [];
    let c = Cursor {
        connection: Conn {
            config: default_config_for_test(),
            fd: -1,
            ssl: nullptr,
            tls: false,
            next_request_id: 1,
            lock: make_mutex(),
            closed: false,
            broken: false,
            pool_managed: false,
            pool_checked_out: false,
            server_max_wire_version: 0,
            is_writable_primary: false
        },
        pool: none,
        collection: "users",
        id: 0,
        batch: empty_batch,
        index: 0,
        batch_size: 0,
        closed: false
    };
    let first = document();
    mongo_operations_test_add(first, "name", string_value("Ada"));
    let values: [Value] = [];
    push(values, document_value(first));
    let response = document();
    mongo_operations_test_add(response, "id", int64_value(0));
    mongo_operations_test_add(response, "firstBatch", array_value(values));
    let updated = mongo_cursor_update(c, response, "firstBatch");
    guard let _updated = updated else let e = err_of(updated) { panic(e); }
    let next = cursor_next(c, mongo_operations_deadline());
    guard let item = next else let e = err_of(next) { panic(e); }
    guard let found = item else { panic("cursor omitted its first document"); }
    let name = get(found, "name");
    guard let name_value = name else { panic("cursor document lost its field"); }
    let text = as_string(name_value);
    guard let name_text = text else let e = err_of(text) { panic(e); }
    assert(name_text == "Ada");
    let finished = cursor_next(c, mongo_operations_deadline());
    guard let final_item = finished else let e = err_of(finished) { panic(e); }
    guard let _extra = final_item else { return; }
    panic("cursor returned a document after its exhausted batch");
}

fn test_mongo_cursor_deadline_releases_connection() {
    let conn = Conn {
        config: default_config_for_test(),
        fd: -1,
        ssl: nullptr,
        tls: false,
        next_request_id: 1,
        lock: make_mutex(),
        closed: false,
        broken: false,
        pool_managed: false,
        pool_checked_out: false,
        server_max_wire_version: 0,
        is_writable_primary: false
    };
    let no_batch: [Value] = [];
    let cur = Cursor {
        connection: conn,
        pool: none,
        collection: "users",
        id: 5,
        batch: no_batch,
        index: 0,
        batch_size: 0,
        closed: false
    };
    let cursor_result = cursor_next(cur, until_of(time.mono()));
    guard let _item = cursor_result else let e = err_of(cursor_result) {
        assert(cur.closed, "cursor stayed open after its deadline");
        assert(conn.closed, "cursor did not close its unusable connection");
        return;
    }
    panic("expired cursor unexpectedly produced a result");
}

fn mongo_operations_deadline() -> until {
    return until_of(time.mono() + 5000000000);
}

fn default_config_for_test() -> Config {
    let r = new_config("localhost", 27017, "test");
    guard let cfg = r else let e = err_of(r) { panic(e); }
    return cfg;
}

fn test_mongo_write_command_errors_are_reported() {
    let reply = document();
    mongo_operations_test_add(reply, "ok", int32_test_value(1));
    let errors: [Value] = [];
    let detail = document();
    mongo_operations_test_add(detail, "code", int32_test_value(11000));
    mongo_operations_test_add(detail, "errmsg", string_value("duplicate key"));
    push(errors, document_value(detail));
    mongo_operations_test_add(reply, "writeErrors", array_value(errors));
    let checked = mongo_check_write_reply(reply);
    guard let _ok = checked else let e = err_of(checked) {
        assert(strings.contains(e, "11000") && strings.contains(e, "duplicate key"), e);
        return;
    }
    panic("writeErrors was reported as a successful write");
}

fn test_mongo_write_concern_error_is_reported() {
    let reply = document();
    let no_write_errors: [Value] = [];
    mongo_operations_test_add(reply, "writeErrors", array_value(no_write_errors));
    let detail = document();
    mongo_operations_test_add(detail, "errmsg", string_value("majority timeout"));
    mongo_operations_test_add(reply, "writeConcernError", document_value(detail));
    let checked = mongo_check_write_reply(reply);
    guard let _ok = checked else let e = err_of(checked) {
        assert(strings.contains(e, "majority timeout"), e);
        return;
    }
    panic("writeConcernError was reported as a successful write");
}

fn mongo_test_op_msg(response_to: int, opcode: int, flags: int, section: int,
                     declared_delta: int, body: Document) -> bytes {
    let encoded = encode(body);
    guard let bson = encoded else let e = err_of(encoded) { panic(e); }
    let actual_length = 21 + len(bson);
    let declared = actual_length + declared_delta;
    let out = builder.new_bytes();
    out.write(to_le(declared)[0..4]);
    out.write(to_le(701)[0..4]);
    out.write(to_le(response_to)[0..4]);
    out.write(to_le(opcode)[0..4]);
    out.write(to_le(flags)[0..4]);
    out.write_byte(section);
    out.write(bson);
    return out.finish();
}

fn mongo_test_op_msg_error(raw: bytes, expected: int, cfg: Config) -> str {
    let decoded = mongo_decode_op_msg(raw, expected, cfg);
    guard let _message = decoded else let e = err_of(decoded) { return e; }
    panic("malformed OP_MSG frame was accepted");
}

fn test_mongo_op_msg_rejects_malformed_envelopes() {
    let config_result = new_config("localhost", 27017, "test");
    guard let cfg = config_result else let e = err_of(config_result) { panic(e); }
    let body = document();
    mongo_operations_test_add(body, "ok", int32_test_value(1));
    let valid = mongo_test_op_msg(7, OP_MSG, 0, 0, 0, body);
    let decoded = mongo_decode_op_msg(valid, 7, cfg);
    guard let _valid_message = decoded else let e = err_of(decoded) { panic(e); }
    assert(mongo_test_op_msg_error(
        mongo_test_op_msg(7, OP_MSG, 0, 0, 0, body), 8, cfg) != "",
        "responseTo mismatch passed");
    assert(mongo_test_op_msg_error(
        mongo_test_op_msg(7, 1, 0, 0, 0, body), 7, cfg) != "",
        "wrong opcode passed");
    assert(mongo_test_op_msg_error(
        mongo_test_op_msg(7, OP_MSG, 1, 0, 0, body), 7, cfg) != "",
        "unsupported flags passed");
    assert(mongo_test_op_msg_error(
        mongo_test_op_msg(7, OP_MSG, 0, 1, 0, body), 7, cfg) != "",
        "unsupported section passed");
    assert(mongo_test_op_msg_error(
        mongo_test_op_msg(7, OP_MSG, 0, 0, 1, body), 7, cfg) != "",
        "declared length mismatch passed");
}

fn int32_test_value(value: int) -> Value {
    let r = int32_value(value);
    guard let out = r else let e = err_of(r) { panic(e); }
    return out;
}

fn mongo_test_read_exact(fd: i32, wanted: int, deadline: until) -> bytes {
    let out = builder.new_bytes();
    while out.size() < wanted {
        let remaining = wanted - out.size();
        let received = net.recv_until(fd, remaining, deadline);
        guard let chunk = received else let e = err_of(received) { panic(e); }
        if len(chunk) == 0 { panic("mock MongoDB peer closed early"); }
        out.write(chunk);
    }
    return out.finish();
}

fn mongo_test_send_message(fd: i32, response_to: int, body: Document,
                           deadline: until) {
    let encoded = encode(body);
    guard let bson = encoded else let e = err_of(encoded) { panic(e); }
    let total = 21 + len(bson);
    let message = builder.new_bytes();
    message.write(to_le(total)[0..4]);
    message.write(to_le(700 + response_to)[0..4]);
    message.write(to_le(response_to)[0..4]);
    message.write(to_le(OP_MSG)[0..4]);
    message.write(to_le(0)[0..4]);
    message.write_byte(0);
    message.write(bson);
    let raw = message.finish();
    let sent = net.send_until(fd, raw, deadline);
    guard let count = sent else let e = err_of(sent) { panic(e); }
    assert(count == len(raw), "mock MongoDB response write was partial");
}

fn mongo_test_command_server(listener: i32, done: chan[int]) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let cfg_result = new_config("127.0.0.1", 27017, "test");
    guard let cfg = cfg_result else let e = err_of(cfg_result) { panic(e); }
    let request_index = 0;
    while request_index < 6 {
        let header = mongo_test_read_exact(fd, 16, deadline);
        let size = mongo_wire_read_i32(header, 0);
        if size < 21 || size > DEFAULT_MAX_MESSAGE_BYTES {
            panic("mock MongoDB request has an invalid length");
        }
        let tail = mongo_test_read_exact(fd, size - 16, deadline);
        let raw = header + tail;
        let request_id = mongo_wire_read_i32(raw, 4);
        let parsed = mongo_decode_op_msg(raw, 0, cfg);
        guard let request = parsed else let e = err_of(parsed) { panic(e); }
        if request_index == 0 {
            assert(has_field(request.body, "hello"), "client did not send hello");
        } else if request_index == 1 {
            assert(has_field(request.body, "insert"), "insert_one sent the wrong command");
        } else if request_index == 2 {
            assert(has_field(request.body, "find"), "find sent the wrong command");
        } else if request_index == 3 {
            assert(has_field(request.body, "getMore"), "cursor sent the wrong command");
        } else if request_index == 4 {
            assert(has_field(request.body, "update"), "update_one sent the wrong command");
        } else {
            assert(has_field(request.body, "delete"), "delete_one sent the wrong command");
        }
        let reply = document();
        mongo_operations_test_add(reply, "ok", double_value(1.0));
        if request_index == 0 {
            mongo_operations_test_add(reply, "maxWireVersion", int32_test_value(21));
            mongo_operations_test_add(reply, "maxBsonObjectSize",
                                      int32_test_value(DEFAULT_MAX_BSON_BYTES));
            mongo_operations_test_add(reply, "maxMessageSizeBytes",
                                      int32_test_value(DEFAULT_MAX_MESSAGE_BYTES));
        } else if request_index == 2 || request_index == 3 {
            let document_value_for_batch = document();
            if request_index == 2 {
                mongo_operations_test_add(document_value_for_batch, "name",
                                          string_value("Ada"));
            } else {
                mongo_operations_test_add(document_value_for_batch, "name",
                                          string_value("Grace"));
            }
            let docs: [Value] = [];
            push(docs, document_value(document_value_for_batch));
            let cursor_reply = document();
            let cursor_id = 42;
            let batch_name = "firstBatch";
            if request_index == 3 {
                cursor_id = 0;
                batch_name = "nextBatch";
            }
            mongo_operations_test_add(cursor_reply, "id", int64_value(cursor_id));
            mongo_operations_test_add(cursor_reply, "ns", string_value("test.users"));
            mongo_operations_test_add(cursor_reply, batch_name, array_value(docs));
            mongo_operations_test_add(reply, "cursor", document_value(cursor_reply));
        } else if request_index > 0 {
            mongo_operations_test_add(reply, "n", int32_test_value(1));
            if request_index == 4 {
                mongo_operations_test_add(reply, "nModified", int32_test_value(1));
            }
        }
        mongo_test_send_message(fd, request_id, reply, deadline);
        request_index = request_index + 1;
    }
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn test_mongo_network_connect_crud_and_cursor_get_more() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_command_server(listener, done);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let connected = connect_config(config, deadline);
    guard let c = connected else let e = err_of(connected) { panic(e); }
    let collection_result = collection(c, "users");
    guard let col = collection_result else let e = err_of(collection_result) { panic(e); }

    let inserted_doc = document();
    mongo_operations_test_add(inserted_doc, "name", string_value("Ada"));
    let inserted = insert_one(col, inserted_doc, deadline);
    guard let _insert_reply = inserted else let e = err_of(inserted) { panic(e); }

    let options = default_find_options();
    options.batch_size = 1;
    let opened = find(col, document(), options, deadline);
    guard let cur = opened else let e = err_of(opened) { panic(e); }
    let first_result = cursor_next(cur, deadline);
    guard let first_opt = first_result else let e = err_of(first_result) { panic(e); }
    guard let first = first_opt else { panic("first MongoDB batch was empty"); }
    let first_name = get(first, "name");
    guard let first_name_value = first_name else { panic("first document omitted name"); }
    let first_text = as_string(first_name_value);
    guard let first_name_text = first_text else let e = err_of(first_text) { panic(e); }
    assert(first_name_text == "Ada");

    let second_result = cursor_next(cur, deadline);
    guard let second_opt = second_result else let e = err_of(second_result) { panic(e); }
    guard let second = second_opt else { panic("getMore batch was empty"); }
    let second_name = get(second, "name");
    guard let second_name_value = second_name else { panic("second document omitted name"); }
    let second_text = as_string(second_name_value);
    guard let second_name_text = second_text else let e = err_of(second_text) { panic(e); }
    assert(second_name_text == "Grace");
    let exhausted = cursor_next(cur, deadline);
    guard let exhausted_opt = exhausted else let e = err_of(exhausted) { panic(e); }
    guard let _extra = exhausted_opt else {
        let filter = document();
        let update = document();
        mongo_operations_test_add(update, "$set", document_value(document()));
        let updated = update_one(col, filter, update, false, deadline);
        guard let _update_reply = updated else let e = err_of(updated) { panic(e); }
        let deleted = delete_one(col, filter, deadline);
        guard let _delete_reply = deleted else let e = err_of(deleted) { panic(e); }
        close_conn(c);
        chan_recv(done);
        return;
    }
    panic("MongoDB cursor returned extra rows after getMore exhausted it");
}

fn mongo_test_seed_hello_server(listener: i32, writable: bool,
                               done: chan[int]) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let header = mongo_test_read_exact(fd, 16, deadline);
    let size = mongo_wire_read_i32(header, 0);
    if size < 21 || size > DEFAULT_MAX_MESSAGE_BYTES {
        panic("mock seed received an invalid hello length");
    }
    let tail = mongo_test_read_exact(fd, size - 16, deadline);
    let raw = header + tail;
    let request_id = mongo_wire_read_i32(raw, 4);
    let reply = document();
    mongo_operations_test_add(reply, "ok", double_value(1.0));
    mongo_operations_test_add(reply, "maxWireVersion", int32_test_value(21));
    mongo_operations_test_add(reply, "maxBsonObjectSize",
                              int32_test_value(DEFAULT_MAX_BSON_BYTES));
    mongo_operations_test_add(reply, "maxMessageSizeBytes",
                              int32_test_value(DEFAULT_MAX_MESSAGE_BYTES));
    mongo_operations_test_add(reply, "isWritablePrimary", bool_value(writable));
    mongo_operations_test_add(reply, "setName", string_value("rs-test"));
    mongo_test_send_message(fd, request_id, reply, deadline);
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn test_mongo_srv_connect_skips_secondary_and_selects_primary() {
    let first_listener_result = net.listen(0);
    guard let first_listener = first_listener_result else let e = err_of(first_listener_result) { panic(e); }
    let first_port_result = net.port(first_listener);
    guard let first_port = first_port_result else let e = err_of(first_port_result) { panic(e); }
    let second_listener_result = net.listen(0);
    guard let second_listener = second_listener_result else let e = err_of(second_listener_result) { panic(e); }
    let second_port_result = net.port(second_listener);
    guard let second_port = second_port_result else let e = err_of(second_port_result) { panic(e); }
    let first_done: chan[int] = make_chan(1);
    let second_done: chan[int] = make_chan(1);
    spawn mongo_test_seed_hello_server(first_listener, false, first_done);
    spawn mongo_test_seed_hello_server(second_listener, true, second_done);

    let parsed = parse_uri("mongodb+srv://cluster.example.com/db?replicaSet=rs-test&tls=false");
    guard let cfg = parsed else let e = err_of(parsed) { panic(e); }
    let seeds: [MongoSeed] = [];
    push(seeds, MongoSeed { host: "127.0.0.1", port: first_port });
    push(seeds, MongoSeed { host: "127.0.0.1", port: second_port });
    let connected = mongo_connect_seeds(
        cfg, seeds, until_of(time.mono() + 5000000000));
    guard let primary = connected else let e = err_of(connected) { panic(e); }
    assert(primary.is_writable_primary);
    assert(primary.config.port == second_port);
    close_conn(primary);
    chan_recv(first_done);
    chan_recv(second_done);
}

fn mongo_test_pool_server(listener: i32, done: chan[int]) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let cfg_result = new_config("127.0.0.1", 27017, "test");
    guard let cfg = cfg_result else let e = err_of(cfg_result) { panic(e); }
    let request_index = 0;
    while request_index < 2 {
        let header = mongo_test_read_exact(fd, 16, deadline);
        let size = mongo_wire_read_i32(header, 0);
        let tail = mongo_test_read_exact(fd, size - 16, deadline);
        let raw = header + tail;
        let request_id = mongo_wire_read_i32(raw, 4);
        let parsed = mongo_decode_op_msg(raw, 0, cfg);
        guard let request = parsed else let e = err_of(parsed) { panic(e); }
        if request_index == 0 {
            assert(has_field(request.body, "hello"), "pool client did not send hello");
        } else {
            assert(has_field(request.body, "ping"), "pool sent the wrong command");
        }
        let reply = document();
        mongo_operations_test_add(reply, "ok", double_value(1.0));
        if request_index == 0 {
            mongo_operations_test_add(reply, "maxWireVersion", int32_test_value(21));
            mongo_operations_test_add(reply, "maxBsonObjectSize",
                                      int32_test_value(DEFAULT_MAX_BSON_BYTES));
            mongo_operations_test_add(reply, "maxMessageSizeBytes",
                                      int32_test_value(DEFAULT_MAX_MESSAGE_BYTES));
        }
        mongo_test_send_message(fd, request_id, reply, deadline);
        request_index = request_index + 1;
    }
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn mongo_test_pool_command_worker(p: Pool, done: chan[int]) {
    let ping = document();
    mongo_operations_test_add(ping, "ping", int32_test_value(1));
    let command_result = pool_command(p, ping, until_of(time.mono() + 5000000000));
    guard let _reply = command_result else {
        chan_send(done, 0);
        return;
    }
    chan_send(done, 1);
}

fn test_mongo_pool_waiter_gets_released_connection() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let server_done: chan[int] = make_chan(1);
    spawn mongo_test_pool_server(listener, server_done);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let pool_result = new_pool_config_with_limits(config, 1, 2);
    guard let p = pool_result else let e = err_of(pool_result) { panic(e); }
    let held_result = acquire(p, until_of(time.mono() + 5000000000));
    guard let held = held_result else let e = err_of(held_result) { panic(e); }
    let worker_done: chan[int] = make_chan(1);
    spawn mongo_test_pool_command_worker(p, worker_done);
    let waited = 0;
    let attempts = 0;
    while p.waiting == 0 && attempts < 100 {
        time.sleep(1000000);
        attempts = attempts + 1;
    }
    waited = p.waiting;
    assert(waited == 1, "pool waiter did not queue behind its only connection");
    release(p, held);
    let command_result = chan_recv(worker_done);
    guard let command_ok = command_result else {
        panic("pool command worker closed its result channel");
    }
    assert(command_ok == 1, "pool waiter command failed after handoff");
    pool_close(p);
    chan_recv(server_done);
}
