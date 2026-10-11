import "strings";

pub gc struct Collection {
    connection: Conn,
    name: str,
    session: opt[Session],
}

pub gc struct FindOptions {
    projection: opt[Document],
    sort: opt[Document],
    skip: int,
    limit: int,
    batch_size: int,
}

pub gc struct Cursor {
    connection: Conn,
    pool: opt[Pool],
    session: opt[Session],
    session_counted: bool,
    collection: str,
    id: int,
    batch: [Value],
    index: int,
    batch_size: int,
    closed: bool,
}

pub fn collection(c: Conn, name: str) -> result[Collection, str] {
    let valid = mongo_validate_collection(name);
    guard let _valid = valid else let e = err_of(valid) { return err(e); }
    return ok(Collection { connection: c, name: name, session: none });
}

pub fn default_find_options() -> FindOptions {
    let no_projection: opt[Document] = none;
    let no_sort: opt[Document] = none;
    return FindOptions {
        projection: no_projection,
        sort: no_sort,
        skip: 0,
        limit: 0,
        batch_size: 0
    };
}

pub fn insert_one(col: Collection, doc: Document, deadline: until)
                  -> result[Document, str] {
    let docs: [Value] = [];
    push(docs, document_value(doc));
    let command_doc = document();
    let inserted = mongo_put_string(command_doc, "insert", col.name);
    guard let _inserted = inserted else let e = err_of(inserted) { return err(e); }
    let values = put(command_doc, "documents", array_value(docs));
    guard let _values = values else let e = err_of(values) { return err(e); }
    let ordered = put(command_doc, "ordered", bool_value(true));
    guard let _ordered = ordered else let e = err_of(ordered) { return err(e); }
    return mongo_write_command(col, command_doc, deadline);
}

pub fn insert_many(col: Collection, docs: [Document], ordered: bool,
                   deadline: until) -> result[Document, str] {
    if len(docs) == 0 {
        return err("mongo.insert_many: documents cannot be empty");
    }
    if len(docs) > DEFAULT_MAX_BSON_VALUES {
        return err("mongo.insert_many: document count exceeds the BSON value limit");
    }
    let values: [Value] = [];
    let i = 0;
    while i < len(docs) {
        push(values, document_value(docs[i]));
        i = i + 1;
    }
    let command_doc = document();
    let inserted = mongo_put_string(command_doc, "insert", col.name);
    guard let _inserted = inserted else let e = err_of(inserted) { return err(e); }
    let array_added = put(command_doc, "documents", array_value(values));
    guard let _array = array_added else let e = err_of(array_added) { return err(e); }
    let order_added = put(command_doc, "ordered", bool_value(ordered));
    guard let _order = order_added else let e = err_of(order_added) { return err(e); }
    return mongo_write_command(col, command_doc, deadline);
}

pub fn find(col: Collection, filter: Document, options: FindOptions,
            deadline: until) -> result[Cursor, str] {
    let valid_collection = mongo_validate_collection(col.name);
    guard let _collection = valid_collection else let e = err_of(valid_collection) {
        return err(e);
    }
    let valid = mongo_validate_find_options(options);
    guard let _valid = valid else let e = err_of(valid) { return err(e); }
    let command_doc = document();
    let found = mongo_put_string(command_doc, "find", col.name);
    guard let _found = found else let e = err_of(found) { return err(e); }
    let filter_added = put(command_doc, "filter", document_value(filter));
    guard let _filter = filter_added else let e = err_of(filter_added) { return err(e); }
    if options.skip > 0 {
        let skip = int64_value(options.skip);
        let added = put(command_doc, "skip", skip);
        guard let _added = added else let e = err_of(added) { return err(e); }
    }
    if options.limit > 0 {
        let limit = int64_value(options.limit);
        let added = put(command_doc, "limit", limit);
        guard let _added = added else let e = err_of(added) { return err(e); }
    }
    if options.batch_size > 0 {
        let size = int64_value(options.batch_size);
        let added = put(command_doc, "batchSize", size);
        guard let _added = added else let e = err_of(added) { return err(e); }
    }
    if let projection_doc = options.projection {
        let added = put(command_doc, "projection", document_value(projection_doc));
        guard let _added = added else let e = err_of(added) { return err(e); }
    }
    if let sort_doc = options.sort {
        let added = put(command_doc, "sort", document_value(sort_doc));
        guard let _added = added else let e = err_of(added) { return err(e); }
    }
    let reply = mongo_collection_command(col, command_doc, deadline);
    guard let response = reply else let e = err_of(reply) { return err(e); }
    return mongo_cursor_from_reply(col, response, options.batch_size,
                                   "find", deadline);
}

pub fn aggregate(col: Collection, pipeline: [Document], batch_size: int,
                 deadline: until) -> result[Cursor, str] {
    let valid_collection = mongo_validate_collection(col.name);
    guard let _collection = valid_collection else let e = err_of(valid_collection) {
        return err(e);
    }
    let valid_size = mongo_validate_batch_size(batch_size);
    guard let _size = valid_size else let e = err_of(valid_size) { return err(e); }
    if len(pipeline) > DEFAULT_MAX_BSON_VALUES {
        return err("mongo.aggregate: pipeline exceeds the BSON value limit");
    }
    let stages: [Value] = [];
    let i = 0;
    while i < len(pipeline) {
        push(stages, document_value(pipeline[i]));
        i = i + 1;
    }
    let command_doc = document();
    let named = mongo_put_string(command_doc, "aggregate", col.name);
    guard let _named = named else let e = err_of(named) { return err(e); }
    let listed = put(command_doc, "pipeline", bson_array_value_owned(stages));
    guard let _listed = listed else let e = err_of(listed) { return err(e); }
    let cursor_options = document();
    if batch_size > 0 {
        let size = put(cursor_options, "batchSize", int64_value(batch_size));
        guard let _size_added = size else let e = err_of(size) { return err(e); }
    }
    let cursor_added = put(command_doc, "cursor", document_value(cursor_options));
    guard let _cursor = cursor_added else let e = err_of(cursor_added) { return err(e); }
    let response = mongo_collection_command(col, command_doc, deadline);
    guard let reply = response else let e = err_of(response) { return err(e); }
    return mongo_cursor_from_reply(col, reply, batch_size,
                                   "aggregate", deadline);
}

pub fn find_one(col: Collection, filter: Document, deadline: until)
                -> result[opt[Document], str] {
    let options = default_find_options();
    options.limit = 1;
    options.batch_size = 1;
    let opened = find(col, filter, options, deadline);
    guard let cur = opened else let e = err_of(opened) { return err(e); }
    let next = cursor_next(cur, deadline);
    if cur.id != 0 {
        let ignored = cursor_close(cur, deadline);
    }
    return next;
}

pub fn update_one(col: Collection, filter: Document, update: Document,
                  upsert: bool, deadline: until) -> result[Document, str] {
    return mongo_update(col, filter, update, upsert, false, deadline);
}

pub fn update_many(col: Collection, filter: Document, update: Document,
                   upsert: bool, deadline: until) -> result[Document, str] {
    return mongo_update(col, filter, update, upsert, true, deadline);
}

fn mongo_update(col: Collection, filter: Document, update: Document,
                upsert: bool, multi: bool, deadline: until)
                -> result[Document, str] {
    let operation = document();
    let q = put(operation, "q", document_value(filter));
    guard let _q = q else let e = err_of(q) { return err(e); }
    let u = put(operation, "u", document_value(update));
    guard let _u = u else let e = err_of(u) { return err(e); }
    let up = put(operation, "upsert", bool_value(upsert));
    guard let _up = up else let e = err_of(up) { return err(e); }
    let mult = put(operation, "multi", bool_value(multi));
    guard let _mult = mult else let e = err_of(mult) { return err(e); }
    let updates: [Value] = [];
    push(updates, document_value(operation));
    let command_doc = document();
    let named = mongo_put_string(command_doc, "update", col.name);
    guard let _named = named else let e = err_of(named) { return err(e); }
    let listed = put(command_doc, "updates", array_value(updates));
    guard let _listed = listed else let e = err_of(listed) { return err(e); }
    return mongo_write_command(col, command_doc, deadline);
}

pub fn delete_one(col: Collection, filter: Document, deadline: until)
                  -> result[Document, str] {
    return mongo_delete(col, filter, 1, deadline);
}

pub fn delete_many(col: Collection, filter: Document, deadline: until)
                   -> result[Document, str] {
    return mongo_delete(col, filter, 0, deadline);
}

fn mongo_delete(col: Collection, filter: Document, limit: int,
                deadline: until) -> result[Document, str] {
    let operation = document();
    let q = put(operation, "q", document_value(filter));
    guard let _q = q else let e = err_of(q) { return err(e); }
    let limit_value = int32_value(limit);
    guard let limit_bson = limit_value else let e = err_of(limit_value) { return err(e); }
    let l = put(operation, "limit", limit_bson);
    guard let _l = l else let e = err_of(l) { return err(e); }
    let deletes: [Value] = [];
    push(deletes, document_value(operation));
    let command_doc = document();
    let named = mongo_put_string(command_doc, "delete", col.name);
    guard let _named = named else let e = err_of(named) { return err(e); }
    let listed = put(command_doc, "deletes", array_value(deletes));
    guard let _listed = listed else let e = err_of(listed) { return err(e); }
    return mongo_write_command(col, command_doc, deadline);
}

pub fn cursor_next(cur: Cursor, deadline: until)
                   -> result[opt[Document], str] {
    if cur.closed {
        mongo_cursor_release_pool(cur);
        return ok(none);
    }
    let empty_batches = 0;
    while true {
        if cur.index < len(cur.batch) {
            let item = cur.batch[cur.index];
            cur.index = cur.index + 1;
            let doc = as_document(item);
            guard let found = doc else let e = err_of(doc) {
                let ignored = cursor_close(cur, deadline);
                return err("mongo.cursor: batch item is not a document: " + e);
            }
            return ok(some(found));
        }
        if cur.id == 0 {
            cur.closed = true;
            mongo_cursor_release_pool(cur);
            return ok(none);
        }
        if empty_batches >= 16 {
            let ignored = cursor_close(cur, deadline);
            return err("mongo.cursor: server returned too many empty live batches");
        }
        if until_hit(deadline) {
            let ignored = cursor_close(cur, deadline);
            return err("mongo.cursor: deadline expired");
        }
        let more = mongo_cursor_get_more(cur, deadline);
        guard let _continued = more else let e = err_of(more) {
            let ignored = cursor_close(cur, deadline);
            return err(e);
        }
        if len(cur.batch) == 0 {
            empty_batches = empty_batches + 1;
        }
    }
}

pub fn cursor_close(cur: Cursor, deadline: until) -> result[bool, str] {
    if cur.closed || cur.id == 0 {
        cur.closed = true;
        mongo_cursor_release_pool(cur);
        return ok(true);
    }
    let valid_collection = mongo_validate_collection(cur.collection);
    guard let _collection = valid_collection else let e = err_of(valid_collection) {
        cur.closed = true;
        mongo_cursor_release_pool(cur);
        return err(e);
    }
    let ids: [Value] = [];
    push(ids, int64_value(cur.id));
    let command_doc = document();
    let named = mongo_put_string(command_doc, "killCursors", cur.collection);
    guard let _named = named else let e = err_of(named) {
        cur.closed = true;
        return err(e);
    }
    let listed = put(command_doc, "cursors", array_value(ids));
    guard let _listed = listed else let e = err_of(listed) {
        cur.closed = true;
        return err(e);
    }
    let response = mongo_cursor_command(cur, command_doc, deadline);
    cur.closed = true;
    mongo_cursor_release_pool(cur);
    guard let _reply = response else let e = err_of(response) { return err(e); }
    return ok(true);
}

fn mongo_cursor_get_more(cur: Cursor, deadline: until) -> result[bool, str] {
    let valid_collection = mongo_validate_collection(cur.collection);
    guard let _collection = valid_collection else let e = err_of(valid_collection) {
        return err(e);
    }
    let command_doc = document();
    let id_added = put(command_doc, "getMore", int64_value(cur.id));
    guard let _id = id_added else let e = err_of(id_added) { return err(e); }
    let named = mongo_put_string(command_doc, "collection", cur.collection);
    guard let _named = named else let e = err_of(named) { return err(e); }
    if cur.batch_size > 0 {
        let size = put(command_doc, "batchSize", int64_value(cur.batch_size));
        guard let _size = size else let e = err_of(size) { return err(e); }
    }
    let response = mongo_cursor_command(cur, command_doc, deadline);
    guard let reply = response else let e = err_of(response) { return err(e); }
    let cursor_field = get(reply, "cursor");
    guard let cursor_value = cursor_field else {
        return err("mongo.getMore: response omitted cursor");
    }
    let cursor_result = as_document(cursor_value);
    guard let cursor_doc = cursor_result else let e = err_of(cursor_result) {
        return err("mongo.getMore: invalid cursor: " + e);
    }
    return mongo_cursor_update(cur, cursor_doc, "nextBatch");
}

fn mongo_cursor_from_reply(col: Collection, reply: Document, batch_size: int,
                           operation: str, deadline: until)
                          -> result[Cursor, str] {
    let cursor_field = get(reply, "cursor");
    guard let cursor_value = cursor_field else {
        return err("mongo." + operation + ": response omitted cursor");
    }
    let cursor_result = as_document(cursor_value);
    guard let cursor_doc = cursor_result else let e = err_of(cursor_result) {
        return err("mongo." + operation + ": invalid cursor: " + e);
    }
    let no_batch: [Value] = [];
    let cur = Cursor {
        connection: col.connection,
        pool: none,
        session: col.session,
        session_counted: false,
        collection: col.name,
        id: 0,
        batch: no_batch,
        index: 0,
        batch_size: batch_size,
        closed: false
    };
    let loaded = mongo_cursor_update(cur, cursor_doc, "firstBatch");
    guard let _loaded = loaded else let e = err_of(loaded) {
        if cur.id != 0 {
            let ignored = cursor_close(cur, deadline);
        } else {
            cur.closed = true;
        }
        return err(e);
    }
    guard let session = col.session else { return ok(cur); }
    session.active_cursors = session.active_cursors + 1;
    cur.session_counted = true;
    return ok(cur);
}

fn mongo_cursor_update(cur: Cursor, reply: Document, batch_name: str)
                       -> result[bool, str] {
    let id_field = get(reply, "id");
    guard let id_value = id_field else {
        return err("mongo.cursor: response omitted cursor id");
    }
    let id_result = as_int64(id_value);
    guard let id = id_result else let e = err_of(id_result) {
        return err("mongo.cursor: invalid cursor id: " + e);
    }
    cur.id = id;
    let batch_field = get(reply, batch_name);
    guard let batch_value = batch_field else {
        return err("mongo.cursor: response omitted " + batch_name);
    }
    if batch_value.kind != BSON_ARRAY {
        return err("mongo.cursor: invalid batch: value is not a BSON array");
    }
    // The decoded reply owns this immutable-in-practice list. Keeping its
    // reference avoids copying every Value in every network batch.
    let items = batch_value.items;
    if len(items) > DEFAULT_MAX_BSON_VALUES {
        return err("mongo.cursor: batch exceeds configured value limit");
    }
    let i = 0;
    while i < len(items) {
        if items[i].kind != BSON_DOCUMENT {
            return err("mongo.cursor: batch contains a non-document value");
        }
        i = i + 1;
    }
    cur.batch = items;
    cur.index = 0;
    return ok(true);
}

fn mongo_write_command(col: Collection, body: Document, deadline: until)
                       -> result[Document, str] {
    let valid_collection = mongo_validate_collection(col.name);
    guard let _collection = valid_collection else let e = err_of(valid_collection) {
        return err(e);
    }
    let response = mongo_collection_command(col, body, deadline);
    guard let reply = response else let e = err_of(response) { return err(e); }
    let valid = mongo_check_write_reply(reply);
    guard let _valid = valid else let e = err_of(valid) {
        mongo_session_mark_failed(col.session);
        return err(e);
    }
    return ok(reply);
}

fn mongo_check_write_reply(reply: Document) -> result[bool, str] {
    let write_errors = get(reply, "writeErrors");
    if let errors_value = write_errors {
        let errors = as_array(errors_value);
        guard let error_list = errors else {
            return err("mongo.write: malformed writeErrors array");
        }
        if len(error_list) > 0 {
            let first = as_document(error_list[0]);
            guard let detail = first else {
                return err("mongo.write: malformed write error entry");
            }
            let failed = mongo_write_error(detail, "write failed");
            guard let _failed = failed else let e = err_of(failed) { return err(e); }
        }
    }
    let concern = get(reply, "writeConcernError");
    if let concern_value = concern {
        let concern_doc = as_document(concern_value);
        guard let detail = concern_doc else {
            return err("mongo.write: malformed writeConcernError");
        }
        return mongo_write_error(detail, "write concern failed");
    }
    return ok(true);
}

fn mongo_write_error(detail: Document, fallback: str) -> result[bool, str] {
    let message = fallback;
    let msg = get(detail, "errmsg");
    guard let msg_value = msg else {
        return err("mongo.write: " + fallback);
    }
    let msg_text = as_string(msg_value);
    guard let text = msg_text else {
        return err("mongo.write: malformed server error message");
    }
    if len(text) > 1024 {
        message = strings.slice(text, 0, 1024);
    } else {
        message = text;
    }
    let code = get(detail, "code");
    guard let code_value = code else {
        return err("mongo.write: " + message);
    }
    if code_value.kind == BSON_INT32 || code_value.kind == BSON_INT64 {
        return err("mongo.write [" + to_str(code_value.int_value) + "]: " + message);
    }
    return err("mongo.write: " + message);
}

fn mongo_validate_find_options(options: FindOptions) -> result[bool, str] {
    if options.skip < 0 || options.limit < 0 || options.batch_size < 0 ||
       options.skip > 2147483647 || options.limit > 2147483647 ||
       options.batch_size > 2147483647 {
        return err("mongo.find: skip, limit, and batch_size must fit a non-negative int32");
    }
    return ok(true);
}

fn mongo_validate_batch_size(batch_size: int) -> result[bool, str] {
    if batch_size < 0 || batch_size > 2147483647 {
        return err("mongo.aggregate: batch_size must fit a non-negative int32");
    }
    return ok(true);
}

fn mongo_validate_collection(name: str) -> result[bool, str] {
    let raw = to_bytes(name);
    if len(raw) == 0 || len(raw) > 255 || bson_has_zero(raw) {
        return err("mongo.collection: name must be 1 to 255 bytes and contain no NUL");
    }
    if !bson_valid_utf8(raw, 0, len(raw)) {
        return err("mongo.collection: name is not valid UTF-8");
    }
    return ok(true);
}

fn mongo_put_string(doc: Document, key: str, value: str)
                    -> result[bool, str] {
    if bson_has_zero(to_bytes(value)) {
        return err("mongo: string contains NUL");
    }
    return put(doc, key, string_value(value));
}
