import "strings";

// A cursor that yields validated `DocumentView` values. It retains its
// connection; a pooled cursor keeps that pool slot checked out while live.
// Exhaust or close it to release cursor resources. Returned views keep their
// own reference to the batch bytes they use.
pub gc struct ViewCursor {
    connection: Conn,
    pool: opt[Pool],
    session: opt[Session],
    session_counted: bool,
    collection: str,
    id: int,
    raw: bytes,
    batch_pos: int,
    batch_end: int,
    batch_index: int,
    batch_size: int,
    closed: bool,
}

// A cursor over matching documents without constructing a dynamic BSON tree.
// Each response batch is fully validated before any view is returned. Close
// the cursor if iteration stops before it is exhausted.
pub fn find_view(col: Collection, filter: Document, options: FindOptions,
                 deadline: until) -> result[ViewCursor, str] {
    let command = mongo_build_find_command(col.name, filter, options);
    guard let body = command else let e = err_of(command) { return err(e); }
    let response = mongo_collection_command_view(col, body, deadline);
    guard let reply = response else let e = err_of(response) { return err(e); }
    let cursor = mongo_view_cursor_from_reply(col, reply, options.batch_size,
                                              "firstBatch", deadline);
    guard let cur = cursor else let e = err_of(cursor) { return err(e); }
    guard let session = col.session else { return ok(cur); }
    session.active_cursors = session.active_cursors + 1;
    cur.session_counted = true;
    return ok(cur);
}

// A pooled cursor over matching documents without constructing a dynamic BSON
// tree. The pool connection remains checked out until exhaustion or close.
// Each response batch is fully validated before any view is returned.
pub fn pool_find_view(p: Pool, collection_name: str, filter: Document,
                      options: FindOptions, deadline: until)
                     -> result[ViewCursor, str] {
    let acquired = acquire(p, deadline);
    guard let connection = acquired else let e = err_of(acquired) { return err(e); }
    let collection_result = collection(connection, collection_name);
    guard let col = collection_result else let e = err_of(collection_result) {
        release(p, connection);
        return err(e);
    }
    let opened = find_view(col, filter, options, deadline);
    guard let cur = opened else let e = err_of(opened) {
        release(p, connection);
        return err(e);
    }
    cur.pool = some(p);
    if cur.id == 0 && cur.batch_pos == cur.batch_end {
        cur.closed = true;
        mongo_view_cursor_release(cur);
    }
    return ok(cur);
}

// The next document as `ok(some(view))`, or `ok(none)` at end of results.
// When needed, this fetches another batch using `deadline`. End of results
// releases the cursor's batch reference and pooled connection; returned views
// continue to retain the batches they reference. Fetch or validation errors
// close the cursor before returning.
pub fn view_cursor_next(cur: ViewCursor, deadline: until)
                         -> result[opt[DocumentView], str] {
    if cur.closed {
        mongo_view_cursor_release(cur);
        return ok(none);
    }
    let empty_batches = 0;
    while true {
        if cur.batch_pos < cur.batch_end {
            let raw = cur.raw;
            let kind = raw[cur.batch_pos];
            if kind != BSON_DOCUMENT {
                let ignored = view_cursor_close(cur, deadline);
                return err("mongo.view_cursor: batch contains a non-document value");
            }
            let key_start = cur.batch_pos + 1;
            let key_end_result = bson_view_cstring_end(raw, key_start,
                                                        cur.batch_end);
            guard let key_end = key_end_result else let e = err_of(key_end_result) {
                let ignored = view_cursor_close(cur, deadline);
                return err("mongo.view_cursor: invalid batch index: " + e);
            }
            if !bson_view_index_matches(raw, key_start, key_end,
                                        cur.batch_index) {
                let ignored = view_cursor_close(cur, deadline);
                return err("mongo.view_cursor: batch index is not sequential");
            }
            let start = key_end + 1;
            if !bson_has_range(raw, start, 4, cur.batch_end) {
                let ignored = view_cursor_close(cur, deadline);
                return err("mongo.view_cursor: truncated document length");
            }
            let size = bson_read_i32(raw, start);
            if size < 5 || !bson_has_range(raw, start, size, cur.batch_end) ||
               raw[start + size - 1] != 0 {
                let ignored = view_cursor_close(cur, deadline);
                return err("mongo.view_cursor: invalid document boundary");
            }
            cur.batch_pos = start + size;
            cur.batch_index = cur.batch_index + 1;
            return ok(some(bson_view_make_document(raw, start, start + size)));
        }
        if cur.id == 0 {
            cur.closed = true;
            mongo_view_cursor_release(cur);
            return ok(none);
        }
        if empty_batches >= 16 {
            let ignored = view_cursor_close(cur, deadline);
            return err("mongo.view_cursor: server returned too many empty live batches");
        }
        if until_hit(deadline) {
            let ignored = view_cursor_close(cur, deadline);
            return err("mongo.view_cursor: deadline expired");
        }
        let more = mongo_view_cursor_get_more(cur, deadline);
        guard let _continued = more else let e = err_of(more) {
            let ignored = view_cursor_close(cur, deadline);
            return err(e);
        }
        if cur.batch_pos == cur.batch_end {
            empty_batches = empty_batches + 1;
        }
    }
}

// `ok(true)` after closing and releasing the batch and any pooled connection.
// Sends `killCursors` when the cursor is live; closing an exhausted or already
// closed cursor succeeds without sending a command.
pub fn view_cursor_close(cur: ViewCursor, deadline: until)
                         -> result[bool, str] {
    if cur.closed || cur.id == 0 {
        cur.closed = true;
        mongo_view_cursor_release(cur);
        return ok(true);
    }
    let valid = mongo_validate_collection(cur.collection);
    guard let _valid = valid else let e = err_of(valid) {
        cur.closed = true;
        mongo_view_cursor_release(cur);
        return err(e);
    }
    let ids: [Value] = [];
    push(ids, int64_value(cur.id));
    let command = document();
    let named = mongo_put_string(command, "killCursors", cur.collection);
    guard let _named = named else let e = err_of(named) {
        cur.closed = true;
        mongo_view_cursor_release(cur);
        return err(e);
    }
    let listed = put(command, "cursors", array_value(ids));
    guard let _listed = listed else let e = err_of(listed) {
        cur.closed = true;
        mongo_view_cursor_release(cur);
        return err(e);
    }
    let response = mongo_view_cursor_command(cur, command, deadline);
    cur.closed = true;
    mongo_view_cursor_release(cur);
    guard let _reply = response else let e = err_of(response) { return err(e); }
    return ok(true);
}

fn mongo_view_cursor_from_reply(col: Collection, reply: DocumentView,
                                batch_size: int, batch_name: str,
                                deadline: until)
                               -> result[ViewCursor, str] {
    let empty: opt[Pool] = none;
    let cur = ViewCursor {
        connection: col.connection,
        pool: empty,
        session: col.session,
        session_counted: false,
        collection: col.name,
        id: 0,
        raw: b"",
        batch_pos: 0,
        batch_end: 0,
        batch_index: 0,
        batch_size: batch_size,
        closed: false
    };
    let cursor_field = view_get(reply, "cursor");
    guard let cursor_opt = cursor_field else let e = err_of(cursor_field) {
        return err("mongo.find_view: " + e);
    }
    guard let cursor_value = cursor_opt else {
        return err("mongo.find_view: response omitted cursor");
    }
    let cursor_result = view_as_document(cursor_value);
    guard let cursor_doc = cursor_result else let e = err_of(cursor_result) {
        return err("mongo.find_view: invalid cursor: " + e);
    }
    let updated = mongo_view_cursor_update(cur, cursor_doc, batch_name);
    guard let _ok = updated else let e = err_of(updated) {
        if cur.id != 0 {
            let ignored = view_cursor_close(cur, deadline);
        } else {
            cur.closed = true;
        }
        return err(e);
    }
    return ok(cur);
}

fn mongo_view_cursor_update(cur: ViewCursor, reply: DocumentView,
                            batch_name: str) -> result[bool, str] {
    let id_field = view_get(reply, "id");
    guard let id_opt = id_field else let e = err_of(id_field) { return err(e); }
    guard let id_value = id_opt else {
        return err("mongo.view_cursor: response omitted cursor id");
    }
    if view_kind(id_value) != BSON_INT64 {
        return err("mongo.view_cursor: cursor id is not a BSON int64");
    }
    let id_result = view_as_int(id_value);
    guard let id = id_result else let e = err_of(id_result) {
        return err("mongo.view_cursor: invalid cursor id: " + e);
    }
    cur.id = id;
    let batch_field = view_get(reply, batch_name);
    guard let batch_opt = batch_field else let e = err_of(batch_field) { return err(e); }
    guard let batch = batch_opt else {
        return err("mongo.view_cursor: response omitted " + batch_name);
    }
    if view_kind(batch) != BSON_ARRAY {
        return err("mongo.view_cursor: batch is not a BSON array");
    }
    let raw = bson_value_view_raw(batch);
    let pos = bson_value_view_start(batch) + 4;
    let end = bson_value_view_end(batch) - 1;
    let index = 0;
    let at = pos;
    while at < end {
        if raw[at] != BSON_DOCUMENT {
            return err("mongo.view_cursor: batch contains a non-document value");
        }
        let key_start = at + 1;
        let key_end_result = bson_view_cstring_end(raw, key_start, end);
        guard let key_end = key_end_result else let e = err_of(key_end_result) {
            return err("mongo.view_cursor: invalid batch index: " + e);
        }
        if !bson_view_index_matches(raw, key_start, key_end, index) {
            return err("mongo.view_cursor: batch index is not sequential");
        }
        let document_start = key_end + 1;
        if !bson_has_range(raw, document_start, 4, end) {
            return err("mongo.view_cursor: truncated document length");
        }
        let size = bson_read_i32(raw, document_start);
        if size < 5 || !bson_has_range(raw, document_start, size, end) ||
           raw[document_start + size - 1] != 0 {
            return err("mongo.view_cursor: invalid document boundary");
        }
        at = document_start + size;
        index = index + 1;
        if index > DEFAULT_MAX_BSON_VALUES {
            return err("mongo.view_cursor: batch exceeds configured value limit");
        }
    }
    cur.raw = raw;
    cur.batch_pos = pos;
    cur.batch_end = end;
    cur.batch_index = 0;
    return ok(true);
}

fn mongo_view_cursor_get_more(cur: ViewCursor, deadline: until)
                             -> result[bool, str] {
    let valid = mongo_validate_collection(cur.collection);
    guard let _valid = valid else let e = err_of(valid) { return err(e); }
    let command = document();
    let id_added = put(command, "getMore", int64_value(cur.id));
    guard let _id = id_added else let e = err_of(id_added) { return err(e); }
    let named = mongo_put_string(command, "collection", cur.collection);
    guard let _named = named else let e = err_of(named) { return err(e); }
    if cur.batch_size > 0 {
        let size = put(command, "batchSize", int64_value(cur.batch_size));
        guard let _size = size else let e = err_of(size) { return err(e); }
    }
    let response = mongo_view_cursor_command(cur, command, deadline);
    guard let reply = response else let e = err_of(response) { return err(e); }
    let cursor_field = view_get(reply, "cursor");
    guard let cursor_opt = cursor_field else let e = err_of(cursor_field) { return err(e); }
    guard let cursor_value = cursor_opt else {
        return err("mongo.getMore: response omitted cursor");
    }
    let cursor_result = view_as_document(cursor_value);
    guard let cursor_doc = cursor_result else let e = err_of(cursor_result) {
        return err("mongo.getMore: invalid cursor: " + e);
    }
    return mongo_view_cursor_update(cur, cursor_doc, "nextBatch");
}

fn mongo_collection_command_view(col: Collection, body: Document,
                                 deadline: until)
                                -> result[DocumentView, str] {
    guard let session = col.session else {
        return mongo_command_view_on(col.connection,
                                     col.connection.config.database,
                                     body, deadline);
    }
    return mongo_session_command_view(session, col.connection.config.database,
                                      body, deadline);
}

fn mongo_view_cursor_command(cur: ViewCursor, body: Document,
                             deadline: until) -> result[DocumentView, str] {
    guard let session = cur.session else {
        return mongo_command_view_on(cur.connection,
                                     cur.connection.config.database,
                                     body, deadline);
    }
    return mongo_session_command_view(session, cur.connection.config.database,
                                      body, deadline);
}

fn mongo_session_command_view(session: Session, database: str, body: Document,
                              deadline: until) -> result[DocumentView, str] {
    if session.ended {
        return err("mongo.session_command: session has ended");
    }
    if session.transaction_active && session.transaction_failed {
        return err("mongo.session_command: transaction has failed; abort it before issuing more operations");
    }
    let prepared = mongo_session_prepare(session, body, true, false);
    guard let command = prepared else let e = err_of(prepared) { return err(e); }
    if session.transaction_active && !session.transaction_started {
        session.transaction_started = true;
    }
    let response = mongo_command_view_on(session.connection, database,
                                         command, deadline);
    if session.transaction_active {
        guard let _reply = response else let e = err_of(response) {
            session.transaction_failed = true;
            return err(e);
        }
    }
    return response;
}

fn mongo_view_cursor_release(cur: ViewCursor) {
    // A cursor should release the current network batch as soon as it is
    // exhausted or closed. Any returned DocumentView keeps its own reference.
    cur.raw = b"";
    cur.batch_pos = 0;
    cur.batch_end = 0;
    cur.batch_index = 0;
    if cur.session_counted {
        cur.session_counted = false;
        if let session = cur.session {
            if session.active_cursors > 0 {
                session.active_cursors = session.active_cursors - 1;
            }
        }
    }
    if let pool = cur.pool {
        cur.pool = none;
        release(pool, cur.connection);
    }
}
