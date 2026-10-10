import "mongo";
import "time";

fn add(doc: mongo.Document, key: str, value: mongo.Value) {
    let put_result = mongo.put(doc, key, value);
    guard let _ok = put_result else let e = err_of(put_result) { panic(e); }
}

fn make_document() -> mongo.Document {
    let doc = mongo.document();
    let id_result = mongo.int32_value(42);
    guard let id = id_result else let e = err_of(id_result) { panic(e); }
    add(doc, "_id", id);
    add(doc, "name", mongo.string_value("Ada Lovelace"));
    add(doc, "active", mongo.bool_value(true));
    add(doc, "score", mongo.double_value(98.75));
    add(doc, "createdAt", mongo.datetime_value(1700000000123));

    let roles: [mongo.Value] = [];
    push(roles, mongo.string_value("admin"));
    push(roles, mongo.string_value("billing"));
    add(doc, "roles", mongo.array_value(roles));

    let profile = mongo.document();
    add(profile, "city", mongo.string_value("Lagos"));
    add(profile, "country", mongo.string_value("NG"));
    add(doc, "profile", mongo.document_value(profile));
    return doc;
}

fn make_wide_document() -> mongo.Document {
    let doc = mongo.document();
    let i = 0;
    while i < 128 {
        let value_result = mongo.int32_value(i);
        guard let value = value_result else let e = err_of(value_result) { panic(e); }
        add(doc, "field_" + to_str(i), value);
        i = i + 1;
    }
    return doc;
}

fn ns_per_op(start: duration, count: int) -> int {
    return ((time.mono() - start) as int) / count;
}

fn wire_hash(raw: bytes) -> int {
    let hash = 0;
    let i = 0;
    while i < len(raw) {
        hash = (hash * 31 + raw[i]) % 1000000007;
        i = i + 1;
    }
    return hash;
}

fn benchmark(label: str, doc: mongo.Document, iterations: int) {
    let baseline_result = mongo.encode(doc);
    guard let baseline = baseline_result else let e = err_of(baseline_result) { panic(e); }

    let encode_checksum = 0;
    let encode_start = time.mono();
    let i = 0;
    while i < iterations {
        let encoded_result = mongo.encode(doc);
        guard let raw = encoded_result else let e = err_of(encoded_result) { panic(e); }
        encode_checksum = encode_checksum + len(raw);
        i = i + 1;
    }
    let encode_ns = ns_per_op(encode_start, iterations);

    let decode_checksum = 0;
    let decode_start = time.mono();
    let j = 0;
    while j < iterations {
        let decoded_result = mongo.decode(baseline);
        guard let decoded = decoded_result else let e = err_of(decoded_result) { panic(e); }
        decode_checksum = decode_checksum + mongo.document_len(decoded);
        j = j + 1;
    }
    let decode_ns = ns_per_op(decode_start, iterations);

    println("codec=slang shape=" + label +
            " bson_bytes=" + to_str(len(baseline)) +
            " wire_hash=" + to_str(wire_hash(baseline)) +
            " iterations=" + to_str(iterations));
    println("encode_ns_op=" + to_str(encode_ns) +
            " checksum=" + to_str(encode_checksum));
    println("decode_ns_op=" + to_str(decode_ns) +
            " checksum=" + to_str(decode_checksum));
}

benchmark("small", make_document(), 20000);
benchmark("wide128", make_wide_document(), 1000);
