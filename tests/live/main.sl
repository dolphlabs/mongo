import "flags";
import "mongo";
import "proc";
import "strings";
import "time";

fn live_deadline() -> until {
    return until_of(time.mono() + 30000000000);
}

fn live_put(doc: mongo.Document, key: str, value: mongo.Value) {
    let added = mongo.put(doc, key, value);
    guard let _added = added else let e = err_of(added) { panic(e); }
}

fn live_put_int(doc: mongo.Document, key: str, number: int) {
    let value = mongo.int32_value(number);
    guard let wrapped = value else let e = err_of(value) { panic(e); }
    live_put(doc, key, wrapped);
}

fn live_put_string(doc: mongo.Document, key: str, value: str) {
    live_put(doc, key, mongo.string_value(value));
}

fn live_field_int(doc: mongo.Document, key: str) -> int {
    let raw = mongo.get(doc, key);
    guard let value = raw else { panic("live MongoDB result omitted " + key); }
    let number = mongo.as_int(value);
    guard let parsed = number else let e = err_of(number) { panic(e); }
    return parsed;
}

fn live_field_string(doc: mongo.Document, key: str) -> str {
    let raw = mongo.get(doc, key);
    guard let value = raw else { panic("live MongoDB result omitted " + key); }
    let text = mongo.as_string(value);
    guard let parsed = text else let e = err_of(text) { panic(e); }
    return parsed;
}

fn live_doc_with_id(id: str) -> mongo.Document {
    let doc = mongo.document();
    live_put_string(doc, "_id", id);
    live_put_string(doc, "category", "transaction");
    live_put_int(doc, "score", 1);
    live_put_int(doc, "amount", 1);
    live_put(doc, "active", mongo.bool_value(true));
    return doc;
}

fn live_insert_fixture(pool: mongo.Pool, collection: str, category: str,
                       score: int, amount: int, active: bool) {
    let doc = mongo.document();
    live_put_string(doc, "category", category);
    live_put_int(doc, "score", score);
    live_put_int(doc, "amount", amount);
    live_put(doc, "active", mongo.bool_value(active));
    let inserted = mongo.pool_insert_one(pool, collection, doc, live_deadline());
    guard let reply = inserted else let e = err_of(inserted) { panic(e); }
    assert(live_field_int(reply, "n") == 1, "fixture insert was not acknowledged");
}

fn live_stage(operator: str, body: mongo.Document) -> mongo.Document {
    let stage = mongo.document();
    live_put(stage, operator, mongo.document_value(body));
    return stage;
}

fn live_test_aggregation(pool: mongo.Pool, collection: str) {
    let filter = mongo.document();
    live_put(filter, "active", mongo.bool_value(true));
    let match_stage = live_stage("$match", filter);

    let sort = mongo.document();
    live_put_int(sort, "score", 1);
    let sort_stage = live_stage("$sort", sort);

    let group = mongo.document();
    live_put_string(group, "_id", "$category");
    let sum_amount = mongo.document();
    live_put_string(sum_amount, "$sum", "$amount");
    live_put(group, "total", mongo.document_value(sum_amount));
    let sum_count = mongo.document();
    live_put_int(sum_count, "$sum", 1);
    live_put(group, "count", mongo.document_value(sum_count));
    let max_score = mongo.document();
    live_put_string(max_score, "$max", "$score");
    live_put(group, "maxScore", mongo.document_value(max_score));
    let group_stage = live_stage("$group", group);

    let projection = mongo.document();
    live_put_int(projection, "_id", 1);
    live_put_int(projection, "total", 1);
    live_put_int(projection, "count", 1);
    live_put_int(projection, "maxScore", 1);
    let project_stage = live_stage("$project", projection);

    let pipeline: [mongo.Document] = [];
    push(pipeline, match_stage);
    push(pipeline, sort_stage);
    push(pipeline, group_stage);
    push(pipeline, project_stage);
    let opened = mongo.pool_aggregate(pool, collection, pipeline, 1,
                                      live_deadline());
    guard let cursor = opened else let e = err_of(opened) { panic(e); }
    let blue = false;
    let red = false;
    let count = 0;
    while true {
        let next = mongo.cursor_next(cursor, live_deadline());
        guard let maybe_row = next else let e = err_of(next) { panic(e); }
        guard let row = maybe_row else { break; }
        let category = live_field_string(row, "_id");
        let total = live_field_int(row, "total");
        let grouped_count = live_field_int(row, "count");
        let max_score_value = live_field_int(row, "maxScore");
        if category == "blue" {
            assert(total == 11 && grouped_count == 2 && max_score_value == 3,
                   "blue aggregation result was incorrect");
            blue = true;
        } else if category == "red" {
            assert(total == 3 && grouped_count == 1 && max_score_value == 5,
                   "red aggregation result was incorrect");
            red = true;
        } else {
            panic("aggregation returned an unexpected group " + category);
        }
        count = count + 1;
    }
    assert(count == 2 && blue && red,
           "aggregation did not return both expected groups");
    println("PASS live aggregation match/sort/group/project with getMore");
}

fn live_find_id(pool: mongo.Pool, collection: str, id: str) -> bool {
    let filter = mongo.document();
    live_put_string(filter, "_id", id);
    let options = mongo.default_find_options();
    options.limit = 1;
    options.batch_size = 1;
    let opened = mongo.pool_find(pool, collection, filter, options,
                                 live_deadline());
    guard let cursor = opened else let e = err_of(opened) { panic(e); }
    let next = mongo.cursor_next(cursor, live_deadline());
    guard let maybe_row = next else let e = err_of(next) { panic(e); }
    let found = false;
    if let _row = maybe_row { found = true; }
    let closed = mongo.cursor_close(cursor, live_deadline());
    guard let _closed = closed else let e = err_of(closed) { panic(e); }
    return found;
}

fn live_test_transactions(pool: mongo.Pool, collection: str, suffix: str) {
    let opened = mongo.pool_start_session(pool, live_deadline());
    guard let session = opened else let e = err_of(opened) { panic(e); }
    let target_result = mongo.session_collection(session, collection);
    guard let target = target_result else let e = err_of(target_result) { panic(e); }

    let began = mongo.begin_transaction(session);
    guard let _began = began else let e = err_of(began) { panic(e); }
    let commit_id = "live_commit_" + suffix;
    let committed_doc = live_doc_with_id(commit_id);
    let inserted = mongo.insert_one(target, committed_doc, live_deadline());
    guard let reply = inserted else let e = err_of(inserted) { panic(e); }
    assert(live_field_int(reply, "n") == 1,
           "transactional insert was not acknowledged");
    let committed = mongo.commit_transaction(session, live_deadline());
    guard let _committed = committed else let e = err_of(committed) { panic(e); }
    assert(live_find_id(pool, collection, commit_id),
           "committed transaction document was not visible");

    let began_again = mongo.begin_transaction(session);
    guard let _began_again = began_again else let e = err_of(began_again) { panic(e); }
    let abort_id = "live_abort_" + suffix;
    let aborted_doc = live_doc_with_id(abort_id);
    let inserted_again = mongo.insert_one(target, aborted_doc, live_deadline());
    guard let reply_again = inserted_again else let e = err_of(inserted_again) { panic(e); }
    assert(live_field_int(reply_again, "n") == 1,
           "second transactional insert was not acknowledged");
    let aborted = mongo.abort_transaction(session, live_deadline());
    guard let _aborted = aborted else let e = err_of(aborted) { panic(e); }
    assert(!live_find_id(pool, collection, abort_id),
           "aborted transaction document became visible");

    let ended = mongo.end_session(session, live_deadline());
    guard let _ended = ended else let e = err_of(ended) { panic(e); }
    println("PASS live replica-set transaction commit/abort");
}

fn run_live(uri: str, transactions: bool, collection: str) {
    let parsed = mongo.parse_uri(uri);
    guard let config = parsed else let e = err_of(parsed) { panic(e); }
    let opened = mongo.new_pool(uri, 2);
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    live_insert_fixture(pool, collection, "blue", 3, 4, true);
    live_insert_fixture(pool, collection, "blue", 1, 7, true);
    live_insert_fixture(pool, collection, "red", 5, 3, true);
    live_insert_fixture(pool, collection, "blue", 0, 100, false);
    live_test_aggregation(pool, collection);
    if transactions {
        live_test_transactions(pool, collection, to_str(time.mono()));
    }
    let drop_command = mongo.document();
    live_put_string(drop_command, "drop", collection);
    let dropped = mongo.pool_command_on(pool, config.database, drop_command,
                                        live_deadline());
    guard let _dropped = dropped else let e = err_of(dropped) { panic(e); }
    mongo.pool_close(pool);
    println("PASS live MongoDB checks");
}

fn expect_connect_error(uri: str, expected: str) {
    let opened = mongo.connect(uri, live_deadline());
    guard let connection = opened else let e = err_of(opened) {
        assert(strings.contains(e, expected),
               "connection failed for an unexpected reason: " + e);
        println("PASS live connection rejection: " + expected);
        return;
    }
    mongo.close_conn(connection);
    panic("MongoDB connection unexpectedly succeeded");
}

let fs = flags.new("mongo-live-tests", "Opt-in MongoDB live integration checks");
fs.add_str("uri", "u", "", "MongoDB URI");
fs.require("uri");
fs.add_bool("transactions", "", false,
            "also test transactions on a replica set");
fs.add_str("collection", "c", "slang_live_test",
           "temporary collection name");
fs.add_str("expect-error", "", "",
           "require a connection error containing this text");
let args = fs.parse_or_exit(proc.args());
if args.get_str("expect-error") != "" {
    expect_connect_error(args.get_str("uri"), args.get_str("expect-error"));
} else {
    run_live(args.get_str("uri"), args.get_bool("transactions"),
             args.get_str("collection"));
}
