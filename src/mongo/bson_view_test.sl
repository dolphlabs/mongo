import "strings";

fn bson_view_test_add(doc: Document, key: str, value: Value) {
    let added = put(doc, key, value);
    guard let _ok = added else let e = err_of(added) { panic(e); }
}

fn bson_view_test_encoded(doc: Document) -> bytes {
    let encoded = encode(doc);
    guard let raw = encoded else let e = err_of(encoded) { panic(e); }
    return raw;
}

fn bson_view_test_decoded(raw: bytes) -> DocumentView {
    let decoded = decode_view(raw);
    guard let view = decoded else let e = err_of(decoded) { panic(e); }
    return view;
}

fn bson_view_test_field(doc: DocumentView, key: str) -> ValueView {
    let field = view_get(doc, key);
    guard let found = field else let e = err_of(field) { panic(e); }
    guard let value = found else { panic("missing BSON view field " + key); }
    return value;
}

fn test_bson_view_reads_selected_fields_and_nested_documents() {
    let nested = document();
    bson_view_test_add(nested, "flag", bool_value(true));
    let doc = document();
    bson_view_test_add(doc, "number", int64_value(9000000000));
    bson_view_test_add(doc, "text", string_value("Lagos"));
    bson_view_test_add(doc, "nested", document_value(nested));
    let view = bson_view_test_decoded(bson_view_test_encoded(doc));

    let number_result = view_as_int(bson_view_test_field(view, "number"));
    guard let number = number_result else let e = err_of(number_result) { panic(e); }
    assert(number == 9000000000);
    let text_field = bson_view_test_field(view, "text");
    let text_len = view_string_len(text_field);
    guard let length = text_len else let e = err_of(text_len) { panic(e); }
    assert(length == 5);
    let text_result = view_as_string(text_field);
    guard let text = text_result else let e = err_of(text_result) { panic(e); }
    assert(text == "Lagos");

    let nested_field = bson_view_test_field(view, "nested");
    let nested_result = view_as_document(nested_field);
    guard let nested_view = nested_result else let e = err_of(nested_result) { panic(e); }
    let flag_result = view_as_bool(bson_view_test_field(nested_view, "flag"));
    guard let flag = flag_result else let e = err_of(flag_result) { panic(e); }
    assert(flag);
    let missing = view_get(view, "absent");
    guard let no_value = missing else let e = err_of(missing) { panic(e); }
    if let _unexpected = no_value {
        panic("BSON view returned a missing field");
    }
}

fn test_bson_view_checks_types_and_nul_strings() {
    let doc = document();
    bson_view_test_add(doc, "n", bson_view_test_i32(7));
    let nul_value = string_bytes_value(b"a\x00b");
    guard let nul = nul_value else let e = err_of(nul_value) { panic(e); }
    bson_view_test_add(doc, "nul", nul);
    let view = bson_view_test_decoded(bson_view_test_encoded(doc));

    let nul_field = bson_view_test_field(view, "nul");
    let nul_len_result = view_string_len(nul_field);
    guard let nul_len = nul_len_result else let e = err_of(nul_len_result) { panic(e); }
    assert(nul_len == 3);
    let nul_text = view_as_string(nul_field);
    guard let _text = nul_text else let e = err_of(nul_text) {
        assert(strings.contains(e, "U+0000"), e);
        return;
    }
    panic("BSON view converted a NUL-containing string to slang str");
}

fn test_bson_view_type_mismatch_is_an_error() {
    let doc = document();
    bson_view_test_add(doc, "text", string_value("hello"));
    let view = bson_view_test_decoded(bson_view_test_encoded(doc));
    let number = view_as_int(bson_view_test_field(view, "text"));
    guard let _value = number else let e = err_of(number) {
        assert(e == "bson.view_as_int: value is not a BSON integer or date", e);
        return;
    }
    panic("BSON view coerced a string to an integer");
}

fn test_bson_view_double_and_binary_accessors() {
    let binary_result = binary_value(b"\x01\x02\x03", 128);
    guard let binary = binary_result else let e = err_of(binary_result) { panic(e); }
    let doc = document();
    bson_view_test_add(doc, "number", double_value(1.25));
    bson_view_test_add(doc, "blob", binary);
    let view = bson_view_test_decoded(bson_view_test_encoded(doc));

    let number = view_as_double(bson_view_test_field(view, "number"));
    guard let parsed_number = number else let e = err_of(number) { panic(e); }
    assert(parsed_number == 1.25);

    let blob_field = bson_view_test_field(view, "blob");
    assert(view_kind(blob_field) == BSON_BINARY);
    let blob_result = view_as_binary(blob_field);
    guard let blob = blob_result else let e = err_of(blob_result) { panic(e); }
    assert(len(blob) == 3 && blob[0] == 1 && blob[1] == 2 && blob[2] == 3);
}

fn test_bson_view_rejects_malformed_documents() {
    let truncated_nested = b"\x0c\x00\x00\x00\x03x\x00\x06\x00\x00\x00\x00";
    assert(bson_view_test_error(truncated_nested) ==
           "bson.decode_view: invalid or out-of-bounds nested document");
    let duplicate = b"\x0b\x00\x00\x00\x0ax\x00\x0ax\x00\x00";
    assert(bson_view_test_error(duplicate) ==
           "bson.decode_view: duplicate field name x");
    let bad_bool = b"\x09\x00\x00\x00\x08x\x00\x02\x00";
    assert(bson_view_test_error(bad_bool) ==
           "bson.decode_view: boolean byte must be 0 or 1");
    let bad_utf8 = b"\x0f\x00\x00\x00\x02x\x00\x03\x00\x00\x00\xc0\xaf\x00\x00";
    assert(bson_view_test_error(bad_utf8) ==
           "bson.decode_view: string value is not valid UTF-8");
    let bad_array_index = b"\x14\x00\x00\x00\x04a\x00\x0c\x00\x00\x00\x10\x31\x00\x01\x00\x00\x00\x00\x00";
    assert(bson_view_test_error(bad_array_index) ==
           "bson.decode_view: array index is not the expected 0");
}

fn test_bson_view_enforces_document_depth_and_value_limits() {
    let nested = document();
    bson_view_test_add(nested, "n", bson_view_test_i32(1));
    let doc = document();
    bson_view_test_add(doc, "a", document_value(nested));
    bson_view_test_add(doc, "b", bson_view_test_i32(2));
    let raw = bson_view_test_encoded(doc);

    let byte_limits_result = new_limits(5, 10, 10);
    guard let byte_limits = byte_limits_result else let e = err_of(byte_limits_result) { panic(e); }
    assert(bson_view_test_error_with_limits(raw, byte_limits) ==
           "bson.decode_view: document exceeds configured byte limit");

    let depth_limits_result = new_limits(128, 1, 10);
    guard let depth_limits = depth_limits_result else let e = err_of(depth_limits_result) { panic(e); }
    assert(bson_view_test_error_with_limits(raw, depth_limits) ==
           "bson.decode_view: nesting depth exceeds configured limit");

    let count_limits_result = new_limits(128, 10, 1);
    guard let count_limits = count_limits_result else let e = err_of(count_limits_result) { panic(e); }
    assert(bson_view_test_error_with_limits(raw, count_limits) ==
           "bson.decode_view: value count exceeds configured limit");
}

fn bson_view_test_error(raw: bytes) -> str {
    let decoded = decode_view(raw);
    guard let _view = decoded else let e = err_of(decoded) { return e; }
    return "BSON view accepted malformed input";
}

fn bson_view_test_error_with_limits(raw: bytes, limits: Limits) -> str {
    let decoded = decode_view_with_limits(raw, limits);
    guard let _view = decoded else let e = err_of(decoded) { return e; }
    return "BSON view accepted input over its configured limits";
}

fn bson_view_test_i32(value: int) -> Value {
    let made = int32_value(value);
    guard let out = made else let e = err_of(made) { panic(e); }
    return out;
}
