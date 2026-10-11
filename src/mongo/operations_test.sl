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
            is_writable_primary: false,
            server_set_name: "",
            logical_session_timeout_minutes: 0
        },
        pool: none,
        session: none,
        session_counted: false,
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
        is_writable_primary: false,
        server_set_name: "",
        logical_session_timeout_minutes: 0
    };
    let no_batch: [Value] = [];
    let cur = Cursor {
        connection: conn,
        pool: none,
        session: none,
        session_counted: false,
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

fn mongo_test_pipeline() -> [Document] {
    let match_filter = document();
    mongo_operations_test_add(match_filter, "kind", string_value("event"));
    let match_stage = document();
    mongo_operations_test_add(match_stage, "$match", document_value(match_filter));
    let sort_fields = document();
    mongo_operations_test_add(sort_fields, "seq", int32_test_value(1));
    let sort_stage = document();
    mongo_operations_test_add(sort_stage, "$sort", document_value(sort_fields));
    let stages: [Document] = [];
    push(stages, match_stage);
    push(stages, sort_stage);
    return stages;
}

fn mongo_test_aggregate_server(listener: i32, done: chan[int], mode: int) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let cfg_result = new_config("127.0.0.1", 27017, "test");
    guard let cfg = cfg_result else let e = err_of(cfg_result) { panic(e); }
    let request_count = 3;
    if mode == 2 { request_count = 2; }
    let request_index = 0;
    while request_index < request_count {
        let header = mongo_test_read_exact(fd, 16, deadline);
        let size = mongo_wire_read_i32(header, 0);
        if size < 21 || size > DEFAULT_MAX_MESSAGE_BYTES {
            panic("mock aggregate peer received an invalid request length");
        }
        let tail = mongo_test_read_exact(fd, size - 16, deadline);
        let raw = header + tail;
        let request_id = mongo_wire_read_i32(raw, 4);
        let parsed = mongo_decode_op_msg(raw, 0, cfg);
        guard let request = parsed else let e = err_of(parsed) { panic(e); }
        let reply = document();
        mongo_operations_test_add(reply, "ok", double_value(1.0));
        if request_index == 0 {
            assert(has_field(request.body, "hello"), "aggregate client omitted hello");
            mongo_operations_test_add(reply, "maxWireVersion", int32_test_value(21));
            mongo_operations_test_add(reply, "maxBsonObjectSize",
                                      int32_test_value(DEFAULT_MAX_BSON_BYTES));
            mongo_operations_test_add(reply, "maxMessageSizeBytes",
                                      int32_test_value(DEFAULT_MAX_MESSAGE_BYTES));
        } else if request_index == 1 {
            assert(has_field(request.body, "aggregate"), "pipeline used the wrong command");
            let collection_value = get(request.body, "aggregate");
            guard let collection_bson = collection_value else {
                panic("aggregate command omitted collection");
            }
            let collection_name = as_string(collection_bson);
            guard let collection_text = collection_name else let e = err_of(collection_name) {
                panic(e);
            }
            assert(collection_text == "users", "aggregate targeted the wrong collection");
            let pipeline_value = get(request.body, "pipeline");
            guard let pipeline_bson = pipeline_value else {
                panic("aggregate command omitted pipeline");
            }
            let pipeline_result = as_array(pipeline_bson);
            guard let pipeline = pipeline_result else let e = err_of(pipeline_result) {
                panic(e);
            }
            if mode == 4 {
                assert(len(pipeline) == 0, "empty pipeline changed");
            } else {
                assert(len(pipeline) == 2, "pipeline stage count changed");
                let first_stage = as_document(pipeline[0]);
                guard let match_doc = first_stage else let e = err_of(first_stage) { panic(e); }
                assert(has_field(match_doc, "$match"), "$match stage was not encoded");
                let second_stage = as_document(pipeline[1]);
                guard let sort_doc = second_stage else let e = err_of(second_stage) { panic(e); }
                assert(has_field(sort_doc, "$sort"), "$sort stage was not encoded");
            }
            let cursor_value = get(request.body, "cursor");
            guard let cursor_bson = cursor_value else { panic("aggregate omitted cursor options"); }
            let cursor_result = as_document(cursor_bson);
            guard let cursor_options = cursor_result else let e = err_of(cursor_result) { panic(e); }
            if mode != 4 {
                let size_value = get(cursor_options, "batchSize");
                guard let size_bson = size_value else { panic("aggregate omitted batchSize"); }
                let size_result = as_int(size_bson);
                guard let size = size_result else let e = err_of(size_result) { panic(e); }
                assert(size == 1, "aggregate batch size changed");
            }
            if mode == 2 {
                mongo_operations_test_add(reply, "ok", double_value(0.0));
                mongo_operations_test_add(reply, "errmsg", string_value("pipeline rejected"));
            } else {
                let cursor_reply = document();
                let cursor_id = 77;
                if mode == 4 { cursor_id = 0; }
                mongo_operations_test_add(cursor_reply, "id", int64_value(cursor_id));
                mongo_operations_test_add(cursor_reply, "ns", string_value("test.users"));
                if mode == 1 {
                    mongo_operations_test_add(cursor_reply, "firstBatch", string_value("bad"));
                } else {
                    let docs: [Value] = [];
                    if mode != 4 {
                        let row = document();
                        mongo_operations_test_add(row, "seq", int64_value(1));
                        push(docs, document_value(row));
                    }
                    mongo_operations_test_add(cursor_reply, "firstBatch", array_value(docs));
                }
                mongo_operations_test_add(reply, "cursor", document_value(cursor_reply));
            }
        } else if mode == 0 {
            assert(has_field(request.body, "getMore"), "aggregate cursor omitted getMore");
            let id_value = get(request.body, "getMore");
            guard let id_bson = id_value else { panic("getMore omitted cursor id"); }
            let id_result = as_int64(id_bson);
            guard let id = id_result else let e = err_of(id_result) { panic(e); }
            assert(id == 77, "aggregate getMore used the wrong cursor id");
            let cursor_reply = document();
            mongo_operations_test_add(cursor_reply, "id", int64_value(0));
            let row = document();
            mongo_operations_test_add(row, "seq", int64_value(2));
            let docs: [Value] = [];
            push(docs, document_value(row));
            mongo_operations_test_add(cursor_reply, "nextBatch", array_value(docs));
            mongo_operations_test_add(reply, "cursor", document_value(cursor_reply));
        } else if mode == 4 {
            assert(has_field(request.body, "ping"), "pool connection was not reusable after empty aggregate");
        } else {
            assert(has_field(request.body, "killCursors"), "aggregate cleanup omitted killCursors");
        }
        mongo_test_send_message(fd, request_id, reply, deadline);
        request_index = request_index + 1;
    }
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn test_mongo_aggregate_pipeline_cursor_get_more() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_aggregate_server(listener, done, 0);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let connected = connect_config(config, deadline);
    guard let conn = connected else let e = err_of(connected) { panic(e); }
    let collection_result = collection(conn, "users");
    guard let target = collection_result else let e = err_of(collection_result) { panic(e); }
    let cursor_result = aggregate(target, mongo_test_pipeline(), 1, deadline);
    guard let cursor = cursor_result else let e = err_of(cursor_result) { panic(e); }
    let first_result = cursor_next(cursor, deadline);
    guard let first_opt = first_result else let e = err_of(first_result) { panic(e); }
    guard let first = first_opt else { panic("aggregate firstBatch was empty"); }
    let first_seq = get(first, "seq");
    guard let first_value = first_seq else { panic("aggregate first row omitted seq"); }
    let first_number = as_int(first_value);
    guard let first_int = first_number else let e = err_of(first_number) { panic(e); }
    assert(first_int == 1, "aggregate first batch returned the wrong row");
    let second_result = cursor_next(cursor, deadline);
    guard let second_opt = second_result else let e = err_of(second_result) { panic(e); }
    guard let second = second_opt else { panic("aggregate getMore batch was empty"); }
    let second_seq = get(second, "seq");
    guard let second_value = second_seq else { panic("aggregate second row omitted seq"); }
    let second_number = as_int(second_value);
    guard let second_int = second_number else let e = err_of(second_number) { panic(e); }
    assert(second_int == 2, "aggregate getMore returned the wrong row");
    let exhausted = cursor_next(cursor, deadline);
    guard let exhausted_opt = exhausted else let e = err_of(exhausted) { panic(e); }
    guard let _extra = exhausted_opt else {
        close_conn(conn);
        chan_recv(done);
        return;
    }
    panic("aggregate cursor returned an extra row");
}

fn test_mongo_aggregate_malformed_batch_kills_cursor() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_aggregate_server(listener, done, 1);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let connected = connect_config(config, deadline);
    guard let conn = connected else let e = err_of(connected) { panic(e); }
    let collection_result = collection(conn, "users");
    guard let target = collection_result else let e = err_of(collection_result) { panic(e); }
    let aggregate_result = aggregate(target, mongo_test_pipeline(), 1, deadline);
    guard let _cursor = aggregate_result else let e = err_of(aggregate_result) {
        assert(strings.contains(e, "invalid batch"), e);
        close_conn(conn);
        chan_recv(done);
        return;
    }
    panic("aggregate accepted a malformed firstBatch");
}

fn test_mongo_aggregate_server_error_is_reported() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_aggregate_server(listener, done, 2);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let connected = connect_config(config, deadline);
    guard let conn = connected else let e = err_of(connected) { panic(e); }
    let collection_result = collection(conn, "users");
    guard let target = collection_result else let e = err_of(collection_result) { panic(e); }
    let aggregate_result = aggregate(target, mongo_test_pipeline(), 1, deadline);
    guard let _cursor = aggregate_result else let e = err_of(aggregate_result) {
        assert(strings.contains(e, "pipeline rejected"), e);
        close_conn(conn);
        chan_recv(done);
        return;
    }
    panic("aggregate server error was reported as success");
}

fn test_mongo_aggregate_cursor_closes_early() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_aggregate_server(listener, done, 3);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let connected = connect_config(config, deadline);
    guard let conn = connected else let e = err_of(connected) { panic(e); }
    let collection_result = collection(conn, "users");
    guard let target = collection_result else let e = err_of(collection_result) { panic(e); }
    let cursor_result = aggregate(target, mongo_test_pipeline(), 1, deadline);
    guard let cursor = cursor_result else let e = err_of(cursor_result) { panic(e); }
    let first = cursor_next(cursor, deadline);
    guard let first_opt = first else let e = err_of(first) { panic(e); }
    guard let _row = first_opt else { panic("aggregate early-close batch was empty"); }
    let closed = cursor_close(cursor, deadline);
    guard let _closed = closed else let e = err_of(closed) { panic(e); }
    close_conn(conn);
    chan_recv(done);
}

fn mongo_test_view_server(listener: i32, done: chan[int]) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let cfg_result = new_config("127.0.0.1", 27017, "test");
    guard let cfg = cfg_result else let e = err_of(cfg_result) { panic(e); }
    let request_index = 0;
    while request_index < 2 {
        let header = mongo_test_read_exact(fd, 16, deadline);
        let size = mongo_wire_read_i32(header, 0);
        if size < 21 || size > DEFAULT_MAX_MESSAGE_BYTES {
            panic("mock MongoDB view request has an invalid length");
        }
        let tail = mongo_test_read_exact(fd, size - 16, deadline);
        let raw = header + tail;
        let request_id = mongo_wire_read_i32(raw, 4);
        let parsed = mongo_decode_op_msg(raw, 0, cfg);
        guard let request = parsed else let e = err_of(parsed) { panic(e); }
        if request_index == 0 {
            assert(has_field(request.body, "find"), "view cursor sent the wrong initial command");
        } else {
            assert(has_field(request.body, "getMore"), "view cursor did not request its next batch");
        }
        let row = document();
        mongo_operations_test_add(row, "seq", int64_value(request_index + 1));
        mongo_operations_test_add(row, "payload", string_value("view payload"));
        let rows: [Value] = [];
        push(rows, document_value(row));
        let cursor_reply = document();
        if request_index == 0 {
            mongo_operations_test_add(cursor_reply, "id", int64_value(42));
            mongo_operations_test_add(cursor_reply, "firstBatch", array_value(rows));
        } else {
            mongo_operations_test_add(cursor_reply, "id", int64_value(0));
            mongo_operations_test_add(cursor_reply, "nextBatch", array_value(rows));
        }
        mongo_operations_test_add(cursor_reply, "ns", string_value("test.users"));
        let reply = document();
        mongo_operations_test_add(reply, "ok", double_value(1.0));
        mongo_operations_test_add(reply, "cursor", document_value(cursor_reply));
        mongo_test_send_message(fd, request_id, reply, deadline);
        request_index = request_index + 1;
    }
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn test_mongo_find_view_reads_first_and_next_batch() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_view_server(listener, done);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let cfg = config_result else let e = err_of(config_result) { panic(e); }
    let dialed = net.dial_until("127.0.0.1", port, deadline);
    guard let fd = dialed else let e = err_of(dialed) { panic(e); }
    let c = Conn {
        config: cfg,
        fd: fd,
        ssl: nullptr,
        tls: false,
        next_request_id: 1,
        lock: make_mutex(),
        closed: false,
        broken: false,
        pool_managed: false,
        pool_checked_out: false,
        server_max_wire_version: 0,
        is_writable_primary: false,
        server_set_name: "",
        logical_session_timeout_minutes: 0
    };
    let collection_result = collection(c, "users");
    guard let col = collection_result else let e = err_of(collection_result) { panic(e); }
    let options = default_find_options();
    options.batch_size = 1;
    let opened = find_view(col, document(), options, deadline);
    guard let cur = opened else let e = err_of(opened) { panic(e); }
    let first_result = view_cursor_next(cur, deadline);
    guard let first_opt = first_result else let e = err_of(first_result) { panic(e); }
    guard let first = first_opt else { panic("view cursor omitted its first document"); }
    let first_seq_result = view_as_int(bson_view_test_field(first, "seq"));
    guard let first_seq = first_seq_result else let e = err_of(first_seq_result) { panic(e); }
    assert(first_seq == 1);
    let first_payload = view_string_len(bson_view_test_field(first, "payload"));
    guard let first_payload_len = first_payload else let e = err_of(first_payload) { panic(e); }
    assert(first_payload_len == 12);

    let second_result = view_cursor_next(cur, deadline);
    guard let second_opt = second_result else let e = err_of(second_result) { panic(e); }
    guard let second = second_opt else { panic("view cursor omitted its next batch"); }
    let second_seq_result = view_as_int(bson_view_test_field(second, "seq"));
    guard let second_seq = second_seq_result else let e = err_of(second_seq_result) { panic(e); }
    assert(second_seq == 2);
    let exhausted = view_cursor_next(cur, deadline);
    guard let no_more = exhausted else let e = err_of(exhausted) { panic(e); }
    if let _unexpected = no_more {
        panic("view cursor returned data after its final batch");
    }
    let retained_result = view_as_int(bson_view_test_field(first, "seq"));
    guard let retained = retained_result else let e = err_of(retained_result) { panic(e); }
    assert(retained == 1, "cursor release invalidated a returned view");
    close_conn(c);
    chan_recv(done);
}

fn test_mongo_pool_aggregate_releases_empty_cursor() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_aggregate_server(listener, done, 4);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let pool_result = new_pool_config(config, 1);
    guard let pool = pool_result else let e = err_of(pool_result) { panic(e); }
    let empty_pipeline: [Document] = [];
    let opened = pool_aggregate(pool, "users", empty_pipeline, 0, deadline);
    guard let cursor = opened else let e = err_of(opened) { panic(e); }
    assert(cursor.closed, "empty aggregate cursor kept a pooled connection checked out");
    let ping = document();
    mongo_operations_test_add(ping, "ping", int32_test_value(1));
    let ping_result = pool_command(pool, ping, deadline);
    guard let _reply = ping_result else let e = err_of(ping_result) { panic(e); }
    pool_close(pool);
    chan_recv(done);
}

fn mongo_test_request_session_id(body: Document) -> bytes {
    let lsid_value = get(body, "lsid");
    guard let lsid_bson = lsid_value else { panic("session command omitted lsid"); }
    let lsid_result = as_document(lsid_bson);
    guard let lsid = lsid_result else let e = err_of(lsid_result) { panic(e); }
    let id_value = get(lsid, "id");
    guard let id_bson = id_value else { panic("lsid omitted id"); }
    assert(id_bson.kind == BSON_BINARY && id_bson.subtype == 4,
           "lsid id is not a UUID binary");
    let id_result = as_binary(id_bson);
    guard let id = id_result else let e = err_of(id_result) { panic(e); }
    assert(len(id) == 16, "lsid UUID is not 16 bytes");
    return id;
}

fn mongo_test_assert_txn_fields(body: Document, id: bytes, number: int,
                                first_operation: bool) {
    let actual_id = mongo_test_request_session_id(body);
    assert(len(actual_id) == len(id), "session UUID length changed");
    let equal = true;
    let i = 0;
    while i < len(id) {
        if actual_id[i] != id[i] { equal = false; }
        i = i + 1;
    }
    assert(equal, "transaction command used a different session id");
    let txn_value = get(body, "txnNumber");
    guard let txn_bson = txn_value else { panic("transaction command omitted txnNumber"); }
    let txn_result = as_int64(txn_bson);
    guard let txn_number = txn_result else let e = err_of(txn_result) { panic(e); }
    assert(txn_number == number, "transaction number changed");
    let autocommit_value = get(body, "autocommit");
    guard let autocommit_bson = autocommit_value else { panic("transaction omitted autocommit"); }
    let autocommit_result = as_bool(autocommit_bson);
    guard let autocommit = autocommit_result else let e = err_of(autocommit_result) { panic(e); }
    assert(!autocommit, "transaction autocommit was not false");
    assert(has_field(body, "startTransaction") == first_operation,
           "startTransaction was not limited to the first operation");
}

fn mongo_test_transaction_server(listener: i32, done: chan[int]) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let cfg_result = new_config("127.0.0.1", 27017, "test");
    guard let cfg = cfg_result else let e = err_of(cfg_result) { panic(e); }
    let first_id: bytes = b"";
    let second_id: bytes = b"";
    let request_index = 0;
    while request_index < 8 {
        let header = mongo_test_read_exact(fd, 16, deadline);
        let size = mongo_wire_read_i32(header, 0);
        if size < 21 || size > DEFAULT_MAX_MESSAGE_BYTES {
            panic("mock transaction peer received an invalid request length");
        }
        let tail = mongo_test_read_exact(fd, size - 16, deadline);
        let raw = header + tail;
        let request_id = mongo_wire_read_i32(raw, 4);
        let parsed = mongo_decode_op_msg(raw, 0, cfg);
        guard let request = parsed else let e = err_of(parsed) { panic(e); }
        let reply = document();
        mongo_operations_test_add(reply, "ok", double_value(1.0));
        if request_index == 0 {
            assert(has_field(request.body, "hello"), "session client omitted hello");
            mongo_operations_test_add(reply, "maxWireVersion", int32_test_value(21));
            mongo_operations_test_add(reply, "maxBsonObjectSize",
                                      int32_test_value(DEFAULT_MAX_BSON_BYTES));
            mongo_operations_test_add(reply, "maxMessageSizeBytes",
                                      int32_test_value(DEFAULT_MAX_MESSAGE_BYTES));
            mongo_operations_test_add(reply, "logicalSessionTimeoutMinutes",
                                      int32_test_value(30));
            mongo_operations_test_add(reply, "setName", string_value("rs-test"));
            mongo_operations_test_add(reply, "isWritablePrimary", bool_value(true));
        } else if request_index == 1 || request_index == 2 {
            assert(has_field(request.body, "insert"), "session CRUD used the wrong command");
            if request_index == 1 {
                first_id = mongo_test_request_session_id(request.body);
                mongo_test_assert_txn_fields(request.body, first_id, 1, true);
            } else {
                second_id = mongo_test_request_session_id(request.body);
                mongo_test_assert_txn_fields(request.body, second_id, 1, true);
                let same = true;
                let i = 0;
                while i < len(first_id) {
                    if first_id[i] != second_id[i] { same = false; }
                    i = i + 1;
                }
                assert(!same, "independent sessions reused the same UUID");
            }
            mongo_operations_test_add(reply, "n", int32_test_value(1));
        } else if request_index == 3 {
            assert(has_field(request.body, "abortTransaction"), "abort used the wrong command");
            mongo_test_assert_txn_fields(request.body, first_id, 1, false);
        } else if request_index == 4 || request_index == 5 {
            assert(has_field(request.body, "commitTransaction"), "commit used the wrong command");
            mongo_test_assert_txn_fields(request.body, second_id, 1, false);
            let concern_value = get(request.body, "writeConcern");
            guard let concern_bson = concern_value else { panic("commit omitted writeConcern"); }
            let concern_result = as_document(concern_bson);
            guard let concern = concern_result else let e = err_of(concern_result) { panic(e); }
            let w_value = get(concern, "w");
            guard let w_bson = w_value else { panic("commit writeConcern omitted w"); }
            let w_result = as_string(w_bson);
            guard let w = w_result else let e = err_of(w_result) { panic(e); }
            assert(w == "majority", "commit did not request majority write concern");
            if request_index == 4 {
                mongo_operations_test_add(reply, "ok", double_value(0.0));
                mongo_operations_test_add(reply, "errmsg", string_value("commit reply lost"));
                let labels: [Value] = [];
                push(labels, string_value("UnknownTransactionCommitResult"));
                mongo_operations_test_add(reply, "errorLabels", array_value(labels));
            }
        } else {
            assert(has_field(request.body, "endSessions"), "session cleanup omitted endSessions");
            let ended = get(request.body, "endSessions");
            guard let ended_value = ended else { panic("endSessions omitted its ids"); }
            let ended_array = as_array(ended_value);
            guard let ended_ids = ended_array else let e = err_of(ended_array) { panic(e); }
            assert(len(ended_ids) == 1, "endSessions had the wrong id count");
        }
        mongo_test_send_message(fd, request_id, reply, deadline);
        request_index = request_index + 1;
    }
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn test_mongo_sessions_transactions_isolate_and_retry_commit_explicitly() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_transaction_server(listener, done);
    let deadline = until_of(time.mono() + 5000000000);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let connected = connect_config(config, deadline);
    guard let conn = connected else let e = err_of(connected) { panic(e); }
    let first_result = start_session(conn);
    guard let first = first_result else let e = err_of(first_result) { panic(e); }
    let second_result = start_session(conn);
    guard let second = second_result else let e = err_of(second_result) { panic(e); }
    let first_collection_result = session_collection(first, "users");
    guard let first_collection = first_collection_result else let e = err_of(first_collection_result) { panic(e); }
    let second_collection_result = session_collection(second, "users");
    guard let second_collection = second_collection_result else let e = err_of(second_collection_result) { panic(e); }
    let first_begin = begin_transaction(first);
    guard let _first_begun = first_begin else let e = err_of(first_begin) { panic(e); }
    let second_begin = begin_transaction(second);
    guard let _second_begun = second_begin else let e = err_of(second_begin) { panic(e); }
    let doc = document();
    mongo_operations_test_add(doc, "kind", string_value("event"));
    let first_insert = insert_one(first_collection, doc, deadline);
    guard let _first_inserted = first_insert else let e = err_of(first_insert) { panic(e); }
    let second_insert = insert_one(second_collection, doc, deadline);
    guard let _second_inserted = second_insert else let e = err_of(second_insert) { panic(e); }
    let aborted = abort_transaction(first, deadline);
    guard let _aborted = aborted else let e = err_of(aborted) { panic(e); }
    let first_commit = commit_transaction(second, deadline);
    guard let _first_commit = first_commit else let e = err_of(first_commit) {
        assert(strings.contains(e, "commit outcome may be unknown"), e);
        assert(strings.contains(e, "UnknownTransactionCommitResult"), e);
        let retried = commit_transaction(second, deadline);
        guard let _retry = retried else let retry_error = err_of(retried) { panic(retry_error); }
        let first_ended = end_session(first, deadline);
        guard let _first_ended = first_ended else let end_error = err_of(first_ended) { panic(end_error); }
        let second_ended = end_session(second, deadline);
        guard let _second_ended = second_ended else let end_error = err_of(second_ended) { panic(end_error); }
        close_conn(conn);
        chan_recv(done);
        return;
    }
    panic("commit with an unknown outcome was silently treated as success");
}

fn mongo_test_pool_session_server(listener: i32, done: chan[int]) {
    let deadline = until_of(time.mono() + 5000000000);
    let accepted = net.accept(listener);
    guard let fd = accepted else let e = err_of(accepted) { panic(e); }
    let cfg_result = new_config("127.0.0.1", 27017, "test");
    guard let cfg = cfg_result else let e = err_of(cfg_result) { panic(e); }
    let expected_id: bytes = b"";
    let request_index = 0;
    while request_index < 5 {
        let header = mongo_test_read_exact(fd, 16, deadline);
        let size = mongo_wire_read_i32(header, 0);
        if size < 21 || size > DEFAULT_MAX_MESSAGE_BYTES {
            panic("mock pooled-session peer received an invalid request length");
        }
        let tail = mongo_test_read_exact(fd, size - 16, deadline);
        let raw = header + tail;
        let request_id = mongo_wire_read_i32(raw, 4);
        let parsed = mongo_decode_op_msg(raw, 0, cfg);
        guard let request = parsed else let e = err_of(parsed) { panic(e); }
        let reply = document();
        mongo_operations_test_add(reply, "ok", double_value(1.0));
        if request_index == 0 {
            assert(has_field(request.body, "hello"), "pool session omitted hello");
            mongo_operations_test_add(reply, "maxWireVersion", int32_test_value(21));
            mongo_operations_test_add(reply, "maxBsonObjectSize",
                                      int32_test_value(DEFAULT_MAX_BSON_BYTES));
            mongo_operations_test_add(reply, "maxMessageSizeBytes",
                                      int32_test_value(DEFAULT_MAX_MESSAGE_BYTES));
            mongo_operations_test_add(reply, "logicalSessionTimeoutMinutes",
                                      int32_test_value(30));
            mongo_operations_test_add(reply, "setName", string_value("rs-test"));
            mongo_operations_test_add(reply, "isWritablePrimary", bool_value(true));
        } else if request_index == 1 {
            assert(has_field(request.body, "insert"), "pool session did not issue insert");
            expected_id = mongo_test_request_session_id(request.body);
            mongo_test_assert_txn_fields(request.body, expected_id, 1, true);
            mongo_operations_test_add(reply, "n", int32_test_value(1));
        } else if request_index == 2 {
            assert(has_field(request.body, "commitTransaction"), "pool session omitted commit");
            mongo_test_assert_txn_fields(request.body, expected_id, 1, false);
        } else if request_index == 3 {
            assert(has_field(request.body, "endSessions"), "pool session omitted endSessions");
        } else {
            assert(has_field(request.body, "ping"), "pool did not reuse the session connection");
        }
        mongo_test_send_message(fd, request_id, reply, deadline);
        request_index = request_index + 1;
    }
    net.close(fd);
    net.close(listener);
    chan_send(done, 1);
}

fn test_mongo_pool_session_pins_then_releases_connection() {
    let listening = net.listen(0);
    guard let listener = listening else let e = err_of(listening) { panic(e); }
    let port_result = net.port(listener);
    guard let port = port_result else let e = err_of(port_result) { panic(e); }
    let done: chan[int] = make_chan(1);
    spawn mongo_test_pool_session_server(listener, done);
    let config_result = new_config("127.0.0.1", port, "test");
    guard let config = config_result else let e = err_of(config_result) { panic(e); }
    let pool_result = new_pool_config(config, 1);
    guard let pool = pool_result else let e = err_of(pool_result) { panic(e); }
    let deadline = until_of(time.mono() + 5000000000);
    let session_result = pool_start_session(pool, deadline);
    guard let session = session_result else let e = err_of(session_result) { panic(e); }
    let target_result = session_collection(session, "users");
    guard let target = target_result else let e = err_of(target_result) { panic(e); }
    let begun = begin_transaction(session);
    guard let _begun = begun else let e = err_of(begun) { panic(e); }
    let doc = document();
    mongo_operations_test_add(doc, "kind", string_value("event"));
    let inserted = insert_one(target, doc, deadline);
    guard let _inserted = inserted else let e = err_of(inserted) { panic(e); }
    let committed = commit_transaction(session, deadline);
    guard let _committed = committed else let e = err_of(committed) { panic(e); }
    let ended = end_session(session, deadline);
    guard let _ended = ended else let e = err_of(ended) { panic(e); }
    let ping = document();
    mongo_operations_test_add(ping, "ping", int32_test_value(1));
    let ping_result = pool_command(pool, ping, deadline);
    guard let _reply = ping_result else let e = err_of(ping_result) { panic(e); }
    pool_close(pool);
    chan_recv(done);
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
