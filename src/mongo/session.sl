import "crypto";

// A Session owns its logical session id and, for pooled sessions, one
// checked-out connection until end_session. Transactions therefore stay on
// one physical connection without adding a second pool or pinning protocol.
pub gc struct Session {
    connection: Conn,
    pool: opt[Pool],
    lsid: Document,
    transaction_number: int,
    transaction_active: bool,
    transaction_started: bool,
    transaction_failed: bool,
    active_cursors: int,
    ended: bool,
}

pub fn start_session(connection: Conn) -> result[Session, str] {
    let no_pool: opt[Pool] = none;
    return mongo_session_create(connection, no_pool);
}

pub fn pool_start_session(pool: Pool, deadline: until)
                         -> result[Session, str] {
    let acquired = acquire(pool, deadline);
    guard let connection = acquired else let e = err_of(acquired) { return err(e); }
    let session = mongo_session_create(connection, some(pool));
    guard let opened = session else let e = err_of(session) {
        release(pool, connection);
        return err(e);
    }
    return ok(opened);
}

fn mongo_session_create(connection: Conn, pool: opt[Pool])
                        -> result[Session, str] {
    if !usable(connection) {
        return err("mongo.start_session: connection is closed or broken");
    }
    if connection.logical_session_timeout_minutes <= 0 {
        return err("mongo.start_session: server does not support logical sessions");
    }
    let random = crypto.rand(16);
    guard let identifier = random else let e = err_of(random) {
        return err("mongo.start_session: secure session id generation failed: " + e);
    }
    if len(identifier) != 16 {
        return err("mongo.start_session: secure session id has an invalid length");
    }
    let binary = binary_value(identifier, 4);
    guard let uuid = binary else let e = err_of(binary) { return err(e); }
    let lsid = document();
    let added = put(lsid, "id", uuid);
    guard let _added = added else let e = err_of(added) { return err(e); }
    return ok(Session {
        connection: connection,
        pool: pool,
        lsid: lsid,
        transaction_number: 0,
        transaction_active: false,
        transaction_started: false,
        transaction_failed: false,
        active_cursors: 0,
        ended: false
    });
}

pub fn session_collection(session: Session, name: str)
                          -> result[Collection, str] {
    if session.ended {
        return err("mongo.session_collection: session has ended");
    }
    let valid = mongo_validate_collection(name);
    guard let _valid = valid else let e = err_of(valid) { return err(e); }
    return ok(Collection {
        connection: session.connection,
        name: name,
        session: some(session)
    });
}

pub fn session_command(session: Session, database: str, body: Document,
                       deadline: until) -> result[Document, str] {
    return mongo_session_command(session, database, body, deadline);
}

fn mongo_session_command(session: Session, database: str, body: Document,
                          deadline: until) -> result[Document, str] {
    if session.ended {
        return err("mongo.session_command: session has ended");
    }
    if session.transaction_active && session.transaction_failed {
        return err("mongo.session_command: transaction has failed; abort it before issuing more operations");
    }
    let prepared = mongo_session_prepare(session, body, true, false);
    guard let command_body = prepared else let e = err_of(prepared) { return err(e); }
    if session.transaction_active && !session.transaction_started {
        session.transaction_started = true;
    }
    let response = command_on(session.connection, database, command_body, deadline);
    if session.transaction_active {
        guard let _reply = response else let e = err_of(response) {
            session.transaction_failed = true;
            return err(e);
        }
    }
    return response;
}

fn mongo_collection_command(col: Collection, body: Document, deadline: until)
                           -> result[Document, str] {
    guard let session = col.session else {
        return command(col.connection, body, deadline);
    }
    return mongo_session_command(session, col.connection.config.database,
                                 body, deadline);
}

fn mongo_cursor_command(cur: Cursor, body: Document, deadline: until)
                         -> result[Document, str] {
    guard let session = cur.session else {
        return command(cur.connection, body, deadline);
    }
    return mongo_session_command(session, cur.connection.config.database,
                                 body, deadline);
}

fn mongo_session_prepare(session: Session, body: Document,
                         include_start: bool, allow_failed: bool)
                         -> result[Document, str] {
    if session.ended {
        return err("mongo.session: session has ended");
    }
    if session.transaction_active && session.transaction_failed && !allow_failed {
        return err("mongo.session: transaction has failed; abort it before issuing more operations");
    }
    let out = document();
    let i = 0;
    while i < len(body.fields) {
        let field = body.fields[i];
        if field.key != "lsid" && field.key != "txnNumber" &&
           field.key != "autocommit" && field.key != "startTransaction" {
            let added = put(out, field.key, field.value);
            guard let _added = added else let e = err_of(added) { return err(e); }
        }
        i = i + 1;
    }
    let lsid_added = put(out, "lsid", document_value(session.lsid));
    guard let _lsid = lsid_added else let e = err_of(lsid_added) { return err(e); }
    if session.transaction_active {
        let number = put(out, "txnNumber", int64_value(session.transaction_number));
        guard let _number = number else let e = err_of(number) { return err(e); }
        let autocommit = put(out, "autocommit", bool_value(false));
        guard let _autocommit = autocommit else let e = err_of(autocommit) { return err(e); }
        if include_start && !session.transaction_started {
            let start = put(out, "startTransaction", bool_value(true));
            guard let _start = start else let e = err_of(start) { return err(e); }
        }
    }
    return ok(out);
}

pub fn begin_transaction(session: Session) -> result[bool, str] {
    if session.ended {
        return err("mongo.begin_transaction: session has ended");
    }
    if session.transaction_active {
        return err("mongo.begin_transaction: a transaction is already active");
    }
    if session.active_cursors != 0 {
        return err("mongo.begin_transaction: close session cursors before starting a transaction");
    }
    if session.connection.server_set_name == "" {
        return err("mongo.begin_transaction: transactions require a replica set");
    }
    if !session.connection.is_writable_primary {
        return err("mongo.begin_transaction: connection is not to the writable primary");
    }
    if session.transaction_number >= 9223372036854775807 {
        return err("mongo.begin_transaction: transaction number is exhausted");
    }
    session.transaction_number = session.transaction_number + 1;
    session.transaction_active = true;
    session.transaction_started = false;
    session.transaction_failed = false;
    return ok(true);
}

pub fn commit_transaction(session: Session, deadline: until)
                           -> result[bool, str] {
    if !session.transaction_active {
        return err("mongo.commit_transaction: no transaction is active");
    }
    if session.active_cursors != 0 {
        return err("mongo.commit_transaction: exhaust or close session cursors first");
    }
    if session.transaction_failed {
        return err("mongo.commit_transaction: transaction operation failed; abort it instead");
    }
    if !session.transaction_started {
        session.transaction_active = false;
        return ok(true);
    }
    let body = document();
    let command = put(body, "commitTransaction", int64_value(1));
    guard let _command = command else let e = err_of(command) { return err(e); }
    let concern = document();
    let majority = put(concern, "w", string_value("majority"));
    guard let _majority = majority else let e = err_of(majority) { return err(e); }
    let write_concern = put(body, "writeConcern", document_value(concern));
    guard let _write_concern = write_concern else let e = err_of(write_concern) { return err(e); }
    let prepared = mongo_session_prepare(session, body, false, false);
    guard let command_body = prepared else let e = err_of(prepared) { return err(e); }
    let response = command_on(session.connection, "admin", command_body, deadline);
    guard let _reply = response else let e = err_of(response) {
        return err("mongo.commit_transaction: commit outcome may be unknown: " + e);
    }
    session.transaction_active = false;
    session.transaction_started = false;
    session.transaction_failed = false;
    return ok(true);
}

pub fn abort_transaction(session: Session, deadline: until)
                          -> result[bool, str] {
    if !session.transaction_active {
        return err("mongo.abort_transaction: no transaction is active");
    }
    if session.active_cursors != 0 {
        return err("mongo.abort_transaction: exhaust or close session cursors first");
    }
    if !session.transaction_started {
        session.transaction_active = false;
        session.transaction_failed = false;
        return ok(true);
    }
    let body = document();
    let command = put(body, "abortTransaction", int64_value(1));
    guard let _command = command else let e = err_of(command) { return err(e); }
    let prepared = mongo_session_prepare(session, body, false, true);
    guard let command_body = prepared else let e = err_of(prepared) { return err(e); }
    let response = command_on(session.connection, "admin", command_body, deadline);
    guard let _reply = response else let e = err_of(response) { return err(e); }
    session.transaction_active = false;
    session.transaction_started = false;
    session.transaction_failed = false;
    return ok(true);
}

pub fn end_session(session: Session, deadline: until) -> result[bool, str] {
    if session.ended {
        return ok(true);
    }
    if session.transaction_active {
        return err("mongo.end_session: commit or abort the active transaction first");
    }
    if session.active_cursors != 0 {
        return err("mongo.end_session: close session cursors first");
    }
    let sessions: [Value] = [];
    push(sessions, document_value(session.lsid));
    let body = document();
    let added = put(body, "endSessions", bson_array_value_owned(sessions));
    guard let _added = added else let e = err_of(added) { return err(e); }
    let response = command_on(session.connection, "admin", body, deadline);
    session.ended = true;
    mongo_session_release_pool(session);
    guard let _reply = response else let e = err_of(response) {
        return err("mongo.end_session: local session ended; server cleanup failed: " + e);
    }
    return ok(true);
}

fn mongo_session_release_pool(session: Session) {
    guard let pool = session.pool else { return; }
    session.pool = none;
    release(pool, session.connection);
}

fn mongo_session_mark_failed(session: opt[Session]) {
    guard let active = session else { return; }
    if active.transaction_active {
        active.transaction_failed = true;
    }
}
