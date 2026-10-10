import "mongodb";
import "time";

fn add(doc: mongodb.Document, key: str, value: mongodb.Value) {
    let put_result = mongodb.put(doc, key, value);
    guard let _ok = put_result else let e = err_of(put_result) { panic(e); }
}

fn make_document() -> mongodb.Document {
    let doc = mongodb.document();
    let id_result = mongodb.int32_value(42);
    guard let id = id_result else let e = err_of(id_result) { panic(e); }
    add(doc, "_id", id);
    add(doc, "name", mongodb.string_value("Ada Lovelace"));
    add(doc, "active", mongodb.bool_value(true));
    add(doc, "score", mongodb.double_value(98.75));
    add(doc, "createdAt", mongodb.datetime_value(1700000000123));

    let roles: [mongodb.Value] = [];
    push(roles, mongodb.string_value("admin"));
    push(roles, mongodb.string_value("billing"));
    add(doc, "roles", mongodb.array_value(roles));

    let profile = mongodb.document();
    add(profile, "city", mongodb.string_value("Lagos"));
    add(profile, "country", mongodb.string_value("NG"));
    add(doc, "profile", mongodb.document_value(profile));
    return doc;
}

fn make_wide_document() -> mongodb.Document {
    let doc = mongodb.document();
    let i = 0;
    while i < 128 {
        let value_result = mongodb.int32_value(i);
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

fn benchmark(label: str, doc: mongodb.Document, iterations: int) {
    let baseline_result = mongodb.encode(doc);
    guard let baseline = baseline_result else let e = err_of(baseline_result) { panic(e); }

    let encode_checksum = 0;
    let encode_start = time.mono();
    let i = 0;
    while i < iterations {
        let encoded_result = mongodb.encode(doc);
        guard let raw = encoded_result else let e = err_of(encoded_result) { panic(e); }
        encode_checksum = encode_checksum + len(raw);
        i = i + 1;
    }
    let encode_ns = ns_per_op(encode_start, iterations);

    let decode_checksum = 0;
    let decode_start = time.mono();
    let j = 0;
    while j < iterations {
        let decoded_result = mongodb.decode(baseline);
        guard let decoded = decoded_result else let e = err_of(decoded_result) { panic(e); }
        decode_checksum = decode_checksum + mongodb.document_len(decoded);
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
