import "mongo";
import "flags";
import "proc";
import "time";

gc struct WorkerResult {
    latencies: [int],
    checks: int,
    failure: str
}

fn add(doc: mongo.Document, key: str, value: mongo.Value)
   -> result[bool, str] {
    return mongo.put(doc, key, value);
}

fn bson_i32(value: int) -> result[mongo.Value, str] {
    return mongo.int32_value(value);
}

fn range_once(pool: mongo.Pool, decoder: str, worker_id: int)
              -> result[int, str] {
    let filter = mongo.document();
    let tenant_id = worker_id % 1000;
    let tenant_value = bson_i32(tenant_id);
    guard let tenant_bson = tenant_value else let e = err_of(tenant_value) { return err(e); }
    let tenant_added = add(filter, "tenant_id", tenant_bson);
    guard let _tenant = tenant_added else let e = err_of(tenant_added) { return err(e); }

    let sort = mongo.document();
    let one = bson_i32(1);
    guard let one_value = one else let e = err_of(one) { return err(e); }
    let sort_added = add(sort, "seq", one_value);
    guard let _sort = sort_added else let e = err_of(sort_added) { return err(e); }

    let options = mongo.default_find_options();
    options.limit = 50;
    options.batch_size = 50;
    options.sort = some(sort);
    let count = 0;
    let last_seq = -1;

    if decoder == "view" {
        let opened = mongo.pool_find_view(pool, "events", filter, options,
                                          until_of(time.mono() + 10000000000));
        guard let cursor = opened else let e = err_of(opened) { return err(e); }
        while true {
            let next = mongo.view_cursor_next(cursor,
                                              until_of(time.mono() + 10000000000));
            guard let maybe_row = next else let e = err_of(next) { return err(e); }
            guard let row = maybe_row else { break; }
            let tenant_result = mongo.view_as_int(mongo_range_view_field(row, "tenant_id"));
            guard let actual_tenant = tenant_result else let e = err_of(tenant_result) { return err(e); }
            let seq_result = mongo.view_as_int(mongo_range_view_field(row, "seq"));
            guard let seq = seq_result else let e = err_of(seq_result) { return err(e); }
            let payload_result = mongo.view_string_len(mongo_range_view_field(row, "payload"));
            guard let payload_len = payload_result else let e = err_of(payload_result) { return err(e); }
            if actual_tenant != tenant_id || seq <= last_seq || payload_len != 1024 {
                return err("view range correctness check failed");
            }
            last_seq = seq;
            count = count + 1;
        }
    } else {
        let opened = mongo.pool_find(pool, "events", filter, options,
                                     until_of(time.mono() + 10000000000));
        guard let cursor = opened else let e = err_of(opened) { return err(e); }
        while true {
            let next = mongo.cursor_next(cursor,
                                         until_of(time.mono() + 10000000000));
            guard let maybe_row = next else let e = err_of(next) { return err(e); }
            guard let row = maybe_row else { break; }
            let tenant_field = mongo.get(row, "tenant_id");
            guard let tenant_value = tenant_field else { return err("range omitted tenant_id"); }
            let tenant_result = mongo.as_int(tenant_value);
            guard let actual_tenant = tenant_result else let e = err_of(tenant_result) { return err(e); }
            let seq_field = mongo.get(row, "seq");
            guard let seq_value = seq_field else { return err("range omitted seq"); }
            let seq_result = mongo.as_int(seq_value);
            guard let seq = seq_result else let e = err_of(seq_result) { return err(e); }
            let payload_field = mongo.get(row, "payload");
            guard let payload_value = payload_field else { return err("range omitted payload"); }
            let payload_result = mongo.as_string(payload_value);
            guard let payload = payload_result else let e = err_of(payload_result) { return err(e); }
            if actual_tenant != tenant_id || seq <= last_seq || len(payload) != 1024 {
                return err("dynamic range correctness check failed");
            }
            last_seq = seq;
            count = count + 1;
        }
    }
    if count != 50 {
        return err("range returned " + to_str(count) + " documents, want 50");
    }
    return ok(count);
}

fn mongo_range_view_field(doc: mongo.DocumentView, key: str)
                          -> mongo.ValueView {
    let found = mongo.view_get(doc, key);
    guard let maybe_value = found else let e = err_of(found) { panic(e); }
    guard let value = maybe_value else { panic("view omitted " + key); }
    return value;
}

fn worker(pool: mongo.Pool, decoder: str, worker_id: int, ops: int,
          ready: chan[int], start: chan[int], done: chan[WorkerResult]) {
    let failure = "";
    let warmup = 0;
    while warmup < 5 {
        let checked = range_once(pool, decoder, worker_id);
        guard let _count = checked else let e = err_of(checked) {
            failure = "warmup worker " + to_str(worker_id) + ": " + e;
            break;
        }
        warmup = warmup + 1;
    }
    chan_send(ready, 1);
    let token = chan_recv(start);
    guard let _go = token else {
        let empty: [int] = [];
        chan_send(done, WorkerResult { latencies: empty, checks: 0,
                                       failure: "start channel closed" });
        return;
    }
    let latencies: [int] = [];
    let checks = 0;
    let i = 0;
    while i < ops && failure == "" {
        let began = time.mono();
        let operation = range_once(pool, decoder, worker_id);
        let elapsed = (time.mono() - began) as int;
        guard let count = operation else let e = err_of(operation) {
            failure = "worker " + to_str(worker_id) + " op " + to_str(i) + ": " + e;
            break;
        }
        push(latencies, elapsed);
        checks = checks + count;
        i = i + 1;
    }
    chan_send(done, WorkerResult { latencies: latencies, checks: checks,
                                   failure: failure });
}

fn sift_down(values: [int], root: int, end: int) {
    let parent = root;
    while true {
        let child = parent * 2 + 1;
        if child > end { break; }
        let largest = child;
        if child + 1 <= end && values[child + 1] > values[child] {
            largest = child + 1;
        }
        if values[parent] >= values[largest] { break; }
        let temp = values[parent];
        values[parent] = values[largest];
        values[largest] = temp;
        parent = largest;
    }
}

fn sort_ints(values: [int]) {
    let start = len(values) / 2 - 1;
    while start >= 0 {
        sift_down(values, start, len(values) - 1);
        start = start - 1;
    }
    let end = len(values) - 1;
    while end > 0 {
        let temp = values[0];
        values[0] = values[end];
        values[end] = temp;
        end = end - 1;
        sift_down(values, 0, end);
    }
}

fn percentile(values: [int], p: int) -> int {
    let index = (len(values) * p + 99) / 100 - 1;
    if index < 0 { index = 0; }
    return values[index];
}

fn run_benchmark(uri: str, decoder: str, workers: int, ops: int) {
    if workers < 1 || workers > 128 || ops < 1 ||
       (decoder != "dynamic" && decoder != "view") {
        panic("decoder must be dynamic or view; workers must be 1..128 and ops positive");
    }
    let opened = mongo.new_pool(uri, workers);
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    let ready: chan[int] = make_chan(workers);
    let start: chan[int] = make_chan(workers);
    let done: chan[WorkerResult] = make_chan(workers);
    for worker_id in 0..workers {
        spawn worker(pool, decoder, worker_id, ops, ready, start, done);
    }
    for worker_id in 0..workers {
        let token = chan_recv(ready);
        guard let _ready = token else { panic("worker readiness channel closed"); }
    }
    let began = time.mono();
    for worker_id in 0..workers {
        chan_send(start, worker_id);
    }
    let latencies: [int] = [];
    let checks = 0;
    let failure = "";
    for worker_id in 0..workers {
        let completed = chan_recv(done);
        guard let worker_done = completed else { panic("worker result channel closed"); }
        if worker_done.failure != "" { failure = worker_done.failure; }
        checks = checks + worker_done.checks;
        for ns in worker_done.latencies { push(latencies, ns); }
    }
    let elapsed = (time.mono() - began) as int;
    mongo.pool_close(pool);
    if failure != "" { panic(failure); }
    if len(latencies) != workers * ops {
        panic("completed " + to_str(len(latencies)) + " operations, expected " +
              to_str(workers * ops));
    }
    sort_ints(latencies);
    let rate = len(latencies) * 1000000000 / elapsed;
    println("RESULT lang=slang decoder=" + decoder +
            " workers=" + to_str(workers) +
            " ops=" + to_str(len(latencies)) +
            " elapsed_ns=" + to_str(elapsed) +
            " throughput_ops_s=" + to_str(rate) +
            " p50_ns=" + to_str(percentile(latencies, 50)) +
            " p95_ns=" + to_str(percentile(latencies, 95)) +
            " p99_ns=" + to_str(percentile(latencies, 99)) +
            " checks=" + to_str(checks) + " errors=0");
}

let args_parser = flags.new("mongo-range-bench", "Read-only sorted BSON range benchmark");
args_parser.add_str("uri", "u", "mongodb://127.0.0.1:27017/slang_mongo_bench_20261011_final", "MongoDB URI");
args_parser.add_str("decoder", "d", "dynamic", "dynamic or view");
args_parser.add_int("workers", "w", 1, "concurrent workers");
args_parser.add_int("ops", "n", 100, "operations per worker");
let args = args_parser.parse_or_exit(proc.args());
run_benchmark(args.get_str("uri"), args.get_str("decoder"),
              args.get_int("workers"), args.get_int("ops"));
