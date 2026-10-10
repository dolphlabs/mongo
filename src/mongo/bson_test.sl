fn bson_test_add(doc: Document, key: str, value: Value) {
    let r = put(doc, key, value);
    guard let _ok = r else let e = err_of(r) {
        panic(e);
    }
}

fn bson_test_i32(value: int) -> Value {
    let r = int32_value(value);
    guard let out = r else let e = err_of(r) {
        panic(e);
    }
    return out;
}

fn bson_test_encoded(doc: Document) -> bytes {
    let r = encode(doc);
    guard let raw = r else let e = err_of(r) {
        panic(e);
    }
    return raw;
}

fn bson_test_decoded(raw: bytes) -> Document {
    let r = decode(raw);
    guard let doc = r else let e = err_of(r) {
        panic(e);
    }
    return doc;
}

fn bson_test_value(doc: Document, key: str) -> Value {
    let r = get(doc, key);
    guard let value = r else {
        panic("missing BSON field " + key);
    }
    return value;
}

fn bson_test_error(raw: bytes, limits: Limits) -> str {
    let r = decode_with_limits(raw, limits);
    guard let _doc = r else let e = err_of(r) {
        return e;
    }
    panic("malformed BSON unexpectedly decoded");
}

fn bson_test_invalid(doc: Document, limits: Limits) -> str {
    let r = encode_with_limits(doc, limits);
    guard let _raw = r else let e = err_of(r) {
        return e;
    }
    panic("BSON value unexpectedly encoded");
}

fn test_bson_known_encoding_and_round_trip() {
    let doc = document();
    bson_test_add(doc, "ok", bool_value(true));
    bson_test_add(doc, "n", bson_test_i32(7));
    bson_test_add(doc, "s", string_value("hi"));
    let raw = bson_test_encoded(doc);
    let expected = b"\x1b\x00\x00\x00\x08ok\x00\x01\x10n\x00\x07\x00\x00\x00\x02s\x00\x03\x00\x00\x00hi\x00\x00";
    assert(len(raw) == len(expected), "BSON length differs");
    let i = 0;
    while i < len(expected) {
        assert(raw[i] == expected[i], "BSON wire byte differs at " + to_str(i));
        i = i + 1;
    }

    let decoded = bson_test_decoded(raw);
    assert(document_len(decoded) == 3);
    assert(has_field(decoded, "ok") && has_field(decoded, "n") &&
           has_field(decoded, "s"));
    let ok_value = bson_test_value(decoded, "ok");
    let br = as_bool(ok_value);
    guard let b = br else let e = err_of(br) { panic(e); }
    assert(b);
    let nr = as_int(bson_test_value(decoded, "n"));
    guard let n = nr else let e = err_of(nr) { panic(e); }
    assert(n == 7);
    let sr = as_string(bson_test_value(decoded, "s"));
    guard let s = sr else let e = err_of(sr) { panic(e); }
    assert(s == "hi");
}

fn test_bson_nested_values_and_all_supported_types() {
    let doc = document();
    let nested = document();
    bson_test_add(nested, "x", double_value(3.141592653589793));
    bson_test_add(nested, "nil", null_value());
    bson_test_add(nested, "at", datetime_value(-123456789));
    bson_test_add(nested, "i64", int64_value(-9223372036854775807));

    let values: [Value] = [];
    push(values, bson_test_i32(-2147483648));
    push(values, string_value("two"));
    push(values, bool_value(false));
    let arr = array_value(values);
    bson_test_add(doc, "nested", document_value(nested));
    bson_test_add(doc, "array", arr);

    let binary = binary_value(b"\x00\xff\x01", 128);
    guard let binary_value_ok = binary else let e = err_of(binary) { panic(e); }
    bson_test_add(doc, "bin", binary_value_ok);
    let oid = object_id_value(b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b");
    guard let oid_value = oid else let e = err_of(oid) { panic(e); }
    bson_test_add(doc, "oid", oid_value);
    let dec = decimal128_value(b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f");
    guard let dec_value = dec else let e = err_of(dec) { panic(e); }
    bson_test_add(doc, "dec", dec_value);
    let regex = regex_value("^abc", "im");
    guard let regex_value_ok = regex else let e = err_of(regex) { panic(e); }
    bson_test_add(doc, "re", regex_value_ok);
    let ts = timestamp_parts(4294967295, 4294967295);
    guard let ts_value = ts else let e = err_of(ts) { panic(e); }
    bson_test_add(doc, "ts", ts_value);
    bson_test_add(doc, "min", min_key_value());
    bson_test_add(doc, "max", max_key_value());

    let decoded = bson_test_decoded(bson_test_encoded(doc));
    let nested_r = as_document(bson_test_value(decoded, "nested"));
    guard let nested_back = nested_r else let e = err_of(nested_r) { panic(e); }
    let pi_r = as_double(bson_test_value(nested_back, "x"));
    guard let pi = pi_r else let e = err_of(pi_r) { panic(e); }
    assert(pi == 3.141592653589793);
    let array_r = as_array(bson_test_value(decoded, "array"));
    guard let array_back = array_r else let e = err_of(array_r) { panic(e); }
    assert(len(array_back) == 3);
    assert(array_back[0].kind == BSON_INT32 && array_back[1].kind == BSON_STRING &&
           array_back[2].kind == BSON_BOOL);
    let binary_back = bson_test_value(decoded, "bin");
    assert(binary_back.kind == BSON_BINARY && binary_back.subtype == 128 &&
           binary_back.data[0] == 0 && binary_back.data[1] == 255);
    let oid_back = bson_test_value(decoded, "oid");
    assert(oid_back.kind == BSON_OBJECT_ID && len(oid_back.data) == 12 &&
           oid_back.data[11] == 11);
    let decimal_back = bson_test_value(decoded, "dec");
    assert(decimal_back.kind == BSON_DECIMAL128 && len(decimal_back.data) == 16 &&
           decimal_back.data[15] == 15);
    assert(bson_test_value(decoded, "re").kind == BSON_REGEX);
    let tsr = as_timestamp_bits(bson_test_value(decoded, "ts"));
    guard let timestamp = tsr else let e = err_of(tsr) { panic(e); }
    assert(timestamp == 18446744073709551615);
    assert(bson_test_value(decoded, "min").kind == BSON_MIN_KEY);
    assert(bson_test_value(decoded, "max").kind == BSON_MAX_KEY);
}

fn test_bson_string_with_nul_is_lossless() {
    let raw_string = b"a\x00b";
    let sv = string_bytes_value(raw_string);
    guard let value = sv else let e = err_of(sv) { panic(e); }
    let doc = document();
    bson_test_add(doc, "s", value);
    let decoded = bson_test_decoded(bson_test_encoded(doc));
    let got = as_string_bytes(bson_test_value(decoded, "s"));
    guard let back = got else let e = err_of(got) { panic(e); }
    assert(len(back) == 3 && back[0] == 97 && back[1] == 0 && back[2] == 98);
    let text = as_string(bson_test_value(decoded, "s"));
    guard let _s = text else let e = err_of(text) {
        assert(e == "bson.as_string: BSON string contains U+0000; use as_string_bytes", e);
        return;
    }
    panic("as_string silently accepted a BSON string with U+0000");
}

fn test_bson_legacy_binary_subtype_two_wire_format() {
    let doc = document();
    let binary = binary_value(b"abc", 2);
    guard let value = binary else let e = err_of(binary) { panic(e); }
    bson_test_add(doc, "b", value);
    let encoded = bson_test_encoded(doc);
    let expected = b"\x14\x00\x00\x00\x05b\x00\x07\x00\x00\x00\x02\x03\x00\x00\x00abc\x00";
    assert(len(encoded) == len(expected), "legacy binary length differs");
    let i = 0;
    while i < len(expected) {
        assert(encoded[i] == expected[i], "legacy binary wire byte differs");
        i = i + 1;
    }
    let decoded = bson_test_decoded(expected);
    let decoded_binary = bson_test_value(decoded, "b");
    assert(decoded_binary.kind == BSON_BINARY && decoded_binary.subtype == 2 &&
           len(decoded_binary.data) == 3 && decoded_binary.data[0] == 97 &&
           decoded_binary.data[2] == 99);

    let malformed = b"\x14\x00\x00\x00\x05b\x00\x07\x00\x00\x00\x02\x02\x00\x00\x00abc\x00";
    assert(bson_test_error(malformed, default_limits()) != "",
           "decoder accepted a mismatched legacy binary length");
}

fn test_bson_put_replaces_and_rejects_bad_values() {
    let doc = document();
    bson_test_add(doc, "x", null_value());
    let replaced = put(doc, "x", bool_value(true));
    guard let _replaced = replaced else let e = err_of(replaced) { panic(e); }
    assert(document_len(doc) == 1, "put duplicated an existing field");
    let current = bson_test_value(doc, "x");
    let current_bool = as_bool(current);
    guard let b = current_bool else let e = err_of(current_bool) { panic(e); }
    assert(b, "put did not replace an existing field");
    let bad_oid = object_id_value(b"short");
    if let _v = bad_oid {
        panic("ObjectId accepted the wrong length");
    } else let e = err_of(bad_oid) {
        assert(e == "bson.object_id_value: ObjectId must be exactly 12 bytes", e);
    }
    let bad_decimal = decimal128_value(b"short");
    if let _d = bad_decimal {
        panic("Decimal128 accepted the wrong length");
    } else let e = err_of(bad_decimal) {
        assert(e == "bson.decimal128_value: Decimal128 must be exactly 16 bytes", e);
    }
    let bad_subtype = binary_value(b"", 256);
    if let _bin = bad_subtype {
        panic("binary accepted an out-of-range subtype");
    } else let e = err_of(bad_subtype) {
        assert(e == "bson.binary_value: subtype must be in range 0 to 255", e);
    }
    let bad_utf8 = string_bytes_value(b"\xc0\xaf");
    if let _str = bad_utf8 {
        panic("string bytes accepted overlong UTF-8");
    } else let e = err_of(bad_utf8) {
        assert(e == "bson.string_bytes_value: bytes are not valid UTF-8", e);
    }

    let unicode_doc = document();
    bson_test_add(unicode_doc, "café", bson_test_i32(5));
    let unicode_back = bson_test_decoded(bson_test_encoded(unicode_doc));
    assert(has_field(unicode_back, "café"));
}

fn test_bson_rejects_malformed_and_over_limit_documents() {
    let limits = default_limits();
    let empty = b"\x05\x00\x00\x00\x00";
    assert(bson_test_error(b"", limits) != "");
    assert(bson_test_error(b"\x05\x00\x00\x00\x01", limits) != "");
    assert(bson_test_error(b"\x06\x00\x00\x00\x00", limits) != "");
    assert(bson_test_error(b"\x06\x00\x00\x00\x00\x00", limits) != "");
    assert(bson_test_error(b"\x08\x00\x00\x00\x0cx\x00\x00", limits) != "");
    assert(bson_test_error(b"\x0c\x00\x00\x00\x02x\x00\xff\xff\xff\xff\x00", limits) != "");
    assert(bson_test_error(b"\x09\x00\x00\x00\x08x\x00\x02\x00", limits) != "");
    assert(bson_test_error(b"\x0d\x00\x00\x00\x03x\x00\x06\x00\x00\x00\x00\x00", limits) != "");
    assert(bson_test_error(b"\x08\x00\x00\x00\x0a\xc0\x00\x00", limits) != "");
    let duplicate = b"\x0b\x00\x00\x00\x0ax\x00\x0ax\x00\x00";
    assert(bson_test_error(duplicate, limits) ==
           "bson.decode: duplicate field name x",
           "decoder accepted duplicate fields");
    assert(bson_test_error(b"\x10\x00\x00\x00\x04a\x00\x08\x00\x00\x00\x0a1\x00\x00\x00", limits) != "");

    let tiny_r = new_limits(5, 2, 10);
    guard let tiny = tiny_r else let e = err_of(tiny_r) { panic(e); }
    let sized = document();
    bson_test_add(sized, "x", string_value("longer than the cap"));
    assert(bson_test_invalid(sized, tiny) != "");

    let depth = document();
    let one = document();
    bson_test_add(one, "x", null_value());
    bson_test_add(depth, "a", document_value(one));
    let shallow_r = new_limits(128, 1, 10);
    guard let shallow = shallow_r else let e = err_of(shallow_r) { panic(e); }
    assert(bson_test_invalid(depth, shallow) != "");

    let count_r = new_limits(128, 4, 1);
    guard let count_limits = count_r else let e = err_of(count_r) { panic(e); }
    assert(bson_test_invalid(depth, count_limits) != "");
    assert(len(bson_test_encoded(document())) == len(empty));
}
