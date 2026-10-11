import "net";
import "time";

let MONGO_POOL_WAIT_NS = 2000000;
let MONGO_POOL_NONE = 0;
let MONGO_POOL_CONN = 1;
let MONGO_POOL_DIAL = 2;
let MONGO_POOL_TIMEOUT = 3;
let MONGO_POOL_CLOSED = 4;
let MONGO_POOL_MAX_OPEN = 1024;
let MONGO_POOL_MAX_WAITERS = 10000;

gc struct MongoIdle {
    connection: Conn,
    next: opt[MongoIdle],
}

gc struct MongoWaiter {
    wake: chan[int],
    deadline: until,
    outcome: int,
    connection: opt[Conn],
    next: opt[MongoWaiter],
}

pub gc struct Pool {
    config: Config,
    max_open: int,
    open: int,
    idle: opt[MongoIdle],
    lock: mutex,
    closed: bool,
    wait_head: opt[MongoWaiter],
    wait_tail: opt[MongoWaiter],
    waiting: int,
    max_waiters: int,
    reaping: bool,
}

pub fn new_pool(uri: str, max_open: int) -> result[Pool, str] {
    let parsed = parse_uri(uri);
    guard let config = parsed else let e = err_of(parsed) { return err(e); }
    return new_pool_config(config, max_open);
}

pub fn new_pool_config(config: Config, max_open: int) -> result[Pool, str] {
    return new_pool_config_with_limits(config, max_open,
                                       MONGO_POOL_MAX_WAITERS);
}

pub fn new_pool_config_with_limits(config: Config, max_open: int,
                                   max_waiters: int) -> result[Pool, str] {
    if max_open < 1 || max_open > MONGO_POOL_MAX_OPEN {
        return err("mongo.new_pool: max_open must be between 1 and 1024");
    }
    if max_waiters < 0 || max_waiters > 1000000 {
        return err("mongo.new_pool: max_waiters must be between 0 and 1000000");
    }
    if config.tls && config.tls_context == nullptr {
        let context = net.tls_client_ctx(config.ca_file);
        guard let tls_context = context else let e = err_of(context) {
            return err("mongo.new_pool: TLS context failed: " + e);
        }
        config.tls_context = tls_context;
    }
    let no_idle: opt[MongoIdle] = none;
    let no_waiter: opt[MongoWaiter] = none;
    return ok(Pool {
        config: config,
        max_open: max_open,
        open: 0,
        idle: no_idle,
        lock: make_mutex(),
        closed: false,
        wait_head: no_waiter,
        wait_tail: no_waiter,
        waiting: 0,
        max_waiters: max_waiters,
        reaping: false
    });
}

fn mongo_pool_has_waiter(value: opt[MongoWaiter]) -> bool {
    guard let _waiter = value else { return false; }
    return true;
}

fn mongo_pool_new_waiter(deadline: until) -> MongoWaiter {
    let no_connection: opt[Conn] = none;
    let no_next: opt[MongoWaiter] = none;
    return MongoWaiter {
        wake: make_chan(1),
        deadline: deadline,
        outcome: MONGO_POOL_NONE,
        connection: no_connection,
        next: no_next
    };
}

fn mongo_pool_enqueue(p: Pool, w: MongoWaiter) {
    let no_next: opt[MongoWaiter] = none;
    w.next = no_next;
    guard let tail = p.wait_tail else {
        p.wait_head = some(w);
        p.wait_tail = some(w);
        return;
    }
    tail.next = some(w);
    p.wait_tail = some(w);
}

fn mongo_pool_pop(p: Pool) -> opt[MongoWaiter] {
    guard let w = p.wait_head else { return none; }
    p.wait_head = w.next;
    w.next = none;
    p.waiting = p.waiting - 1;
    if !mongo_pool_has_waiter(p.wait_head) {
        p.wait_tail = none;
    }
    return some(w);
}

fn mongo_pool_grant(w: MongoWaiter, outcome: int) {
    w.outcome = outcome;
    chan_send(w.wake, 1);
}

fn mongo_pool_pop_live(p: Pool) -> opt[MongoWaiter] {
    while true {
        guard let w = mongo_pool_pop(p) else { return none; }
        if until_hit(w.deadline) {
            mongo_pool_grant(w, MONGO_POOL_TIMEOUT);
            continue;
        }
        return some(w);
    }
}

fn mongo_pool_pass_slot(p: Pool) {
    if p.closed || p.open >= p.max_open { return; }
    guard let w = mongo_pool_pop_live(p) else { return; }
    p.open = p.open + 1;
    mongo_pool_grant(w, MONGO_POOL_DIAL);
}

fn mongo_pool_take_idle(p: Pool) -> opt[Conn] {
    while true {
        guard let node = p.idle else { return none; }
        p.idle = node.next;
        let c = node.connection;
        let alive = net.idle_alive(c.fd);
        if c.ssl != nullptr { alive = net.tls_idle_alive(c.ssl); }
        if !usable(c) || !alive {
            p.open = p.open - 1;
            close_conn(c);
            continue;
        }
        c.pool_checked_out = true;
        return some(c);
    }
}

fn mongo_pool_dial(p: Pool, deadline: until) -> result[Conn, str] {
    let connected = connect_config(p.config, deadline);
    guard let c = connected else let e = err_of(connected) {
        mutex_lock(p.lock);
        p.open = p.open - 1;
        mongo_pool_pass_slot(p);
        mutex_unlock(p.lock);
        return err(e);
    }
    c.pool_managed = true;
    c.pool_checked_out = true;
    mutex_lock(p.lock);
    if p.closed {
        p.open = p.open - 1;
        mutex_unlock(p.lock);
        close_conn(c);
        return err("mongo pool is closed");
    }
    mutex_unlock(p.lock);
    return ok(c);
}

fn mongo_pool_reap(p: Pool) {
    while true {
        time.sleep(MONGO_POOL_WAIT_NS);
        mutex_lock(p.lock);
        let previous: opt[MongoWaiter] = none;
        let current = p.wait_head;
        while true {
            guard let w = current else { break; }
            let next = w.next;
            if until_hit(w.deadline) {
                guard let before = previous else {
                    p.wait_head = next;
                    if !mongo_pool_has_waiter(next) { p.wait_tail = none; }
                    w.next = none;
                    p.waiting = p.waiting - 1;
                    mongo_pool_grant(w, MONGO_POOL_TIMEOUT);
                    current = next;
                    continue;
                }
                before.next = next;
                if !mongo_pool_has_waiter(next) { p.wait_tail = some(before); }
                w.next = none;
                p.waiting = p.waiting - 1;
                mongo_pool_grant(w, MONGO_POOL_TIMEOUT);
                current = next;
                continue;
            }
            previous = some(w);
            current = next;
        }
        if !mongo_pool_has_waiter(p.wait_head) {
            p.reaping = false;
            mutex_unlock(p.lock);
            return;
        }
        mutex_unlock(p.lock);
    }
}

pub fn acquire(p: Pool, deadline: until) -> result[Conn, str] {
    mutex_lock(p.lock);
    if p.closed {
        mutex_unlock(p.lock);
        return err("mongo pool is closed");
    }
    let idle = mongo_pool_take_idle(p);
    guard let c = idle else {
        if p.open < p.max_open {
            p.open = p.open + 1;
            mutex_unlock(p.lock);
            return mongo_pool_dial(p, deadline);
        }
        mutex_unlock(p.lock);
        if until_hit(deadline) {
            return err("mongo pool: timeout waiting for a connection");
        }
        let w = mongo_pool_new_waiter(deadline);
        mutex_lock(p.lock);
        if p.closed {
            mutex_unlock(p.lock);
            return err("mongo pool is closed");
        }
        let idle_again = mongo_pool_take_idle(p);
        guard let available = idle_again else {
            if p.open < p.max_open {
                p.open = p.open + 1;
                mutex_unlock(p.lock);
                return mongo_pool_dial(p, deadline);
            }
            if p.waiting >= p.max_waiters {
                mutex_unlock(p.lock);
                return err("mongo pool: waiter limit reached");
            }
            mongo_pool_enqueue(p, w);
            p.waiting = p.waiting + 1;
            let start_reaper = !p.reaping;
            if start_reaper { p.reaping = true; }
            mutex_unlock(p.lock);
            if start_reaper { spawn mongo_pool_reap(p); }
            chan_recv(w.wake);
            let outcome = w.outcome;
            let handed = w.connection;
            if outcome == MONGO_POOL_CONN {
                guard let granted = handed else {
                    return err("mongo pool: waiter received no connection");
                }
                return ok(granted);
            }
            if outcome == MONGO_POOL_DIAL { return mongo_pool_dial(p, deadline); }
            if outcome == MONGO_POOL_CLOSED { return err("mongo pool is closed"); }
            return err("mongo pool: timeout waiting for a connection");
        }
        mutex_unlock(p.lock);
        available.pool_checked_out = true;
        return ok(available);
    }
    mutex_unlock(p.lock);
    return ok(c);
}

pub fn release(p: Pool, c: Conn) {
    if !c.pool_managed || !c.pool_checked_out {
        panic("mongo.release: connection was not checked out from this pool");
    }
    c.pool_checked_out = false;
    if !usable(c) {
        mutex_lock(p.lock);
        p.open = p.open - 1;
        mongo_pool_pass_slot(p);
        mutex_unlock(p.lock);
        close_conn(c);
        return;
    }
    mutex_lock(p.lock);
    if p.closed {
        p.open = p.open - 1;
        mutex_unlock(p.lock);
        close_conn(c);
        return;
    }
    let waiting = mongo_pool_pop_live(p);
    guard let w = waiting else {
        mutex_unlock(p.lock);
        let no_next: opt[MongoIdle] = none;
        let node = MongoIdle { connection: c, next: no_next };
        mutex_lock(p.lock);
        if p.closed {
            p.open = p.open - 1;
            mutex_unlock(p.lock);
            close_conn(c);
            return;
        }
        let waiting_again = mongo_pool_pop_live(p);
        guard let next_waiter = waiting_again else {
            node.next = p.idle;
            p.idle = some(node);
            mutex_unlock(p.lock);
            return;
        }
        c.pool_checked_out = true;
        next_waiter.connection = some(c);
        mongo_pool_grant(next_waiter, MONGO_POOL_CONN);
        mutex_unlock(p.lock);
        return;
    }
    c.pool_checked_out = true;
    w.connection = some(c);
    mongo_pool_grant(w, MONGO_POOL_CONN);
    mutex_unlock(p.lock);
}

pub fn pool_command(p: Pool, body: Document, deadline: until)
                     -> result[Document, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let response = command(c, body, deadline);
    release(p, c);
    return response;
}

pub fn pool_command_on(p: Pool, database: str, body: Document,
                       deadline: until) -> result[Document, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let response = command_on(c, database, body, deadline);
    release(p, c);
    return response;
}

pub fn pool_find(p: Pool, collection_name: str, filter: Document,
                 options: FindOptions, deadline: until)
                -> result[Cursor, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let col = collection(c, collection_name);
    guard let target = col else let e = err_of(col) {
        release(p, c);
        return err(e);
    }
    let opened = find(target, filter, options, deadline);
    guard let cur = opened else let e = err_of(opened) {
        release(p, c);
        return err(e);
    }
    cur.pool = some(p);
    if cur.id == 0 && len(cur.batch) == 0 {
        cur.closed = true;
        mongo_cursor_release_pool(cur);
    }
    return ok(cur);
}

pub fn pool_aggregate(p: Pool, collection_name: str, pipeline: [Document],
                      batch_size: int, deadline: until)
                     -> result[Cursor, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let col = collection(c, collection_name);
    guard let target = col else let e = err_of(col) {
        release(p, c);
        return err(e);
    }
    let opened = aggregate(target, pipeline, batch_size, deadline);
    guard let cur = opened else let e = err_of(opened) {
        release(p, c);
        return err(e);
    }
    cur.pool = some(p);
    if cur.id == 0 && len(cur.batch) == 0 {
        cur.closed = true;
        mongo_cursor_release_pool(cur);
    }
    return ok(cur);
}

pub fn pool_insert_one(p: Pool, collection_name: str, doc: Document,
                       deadline: until) -> result[Document, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let col = collection(c, collection_name);
    guard let target = col else let e = err_of(col) {
        release(p, c);
        return err(e);
    }
    let response = insert_one(target, doc, deadline);
    release(p, c);
    return response;
}

pub fn pool_update_one(p: Pool, collection_name: str, filter: Document,
                       update: Document, upsert: bool, deadline: until)
                      -> result[Document, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let col = collection(c, collection_name);
    guard let target = col else let e = err_of(col) {
        release(p, c);
        return err(e);
    }
    let response = update_one(target, filter, update, upsert, deadline);
    release(p, c);
    return response;
}

pub fn pool_delete_one(p: Pool, collection_name: str, filter: Document,
                       deadline: until) -> result[Document, str] {
    let acquired = acquire(p, deadline);
    guard let c = acquired else let e = err_of(acquired) { return err(e); }
    let col = collection(c, collection_name);
    guard let target = col else let e = err_of(col) {
        release(p, c);
        return err(e);
    }
    let response = delete_one(target, filter, deadline);
    release(p, c);
    return response;
}

pub fn pool_close(p: Pool) {
    mutex_lock(p.lock);
    if p.closed {
        mutex_unlock(p.lock);
        return;
    }
    p.closed = true;
    while true {
        guard let node = p.idle else { break; }
        p.idle = node.next;
        p.open = p.open - 1;
        close_conn(node.connection);
    }
    while true {
        guard let w = mongo_pool_pop(p) else { break; }
        mongo_pool_grant(w, MONGO_POOL_CLOSED);
    }
    mutex_unlock(p.lock);
}

fn mongo_cursor_release_pool(cur: Cursor) {
    if cur.session_counted {
        cur.session_counted = false;
        guard let session = cur.session else { return; }
        if session.active_cursors > 0 {
            session.active_cursors = session.active_cursors - 1;
        }
    }
    guard let p = cur.pool else { return; }
    cur.pool = none;
    release(p, cur.connection);
}
