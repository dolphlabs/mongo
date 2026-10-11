import "builder";
import "encoding";

// BSON element tags supported by this package.
pub let BSON_DOUBLE = 1;
pub let BSON_STRING = 2;
pub let BSON_DOCUMENT = 3;
pub let BSON_ARRAY = 4;
pub let BSON_BINARY = 5;
pub let BSON_OBJECT_ID = 7;
pub let BSON_BOOL = 8;
pub let BSON_DATETIME = 9;
pub let BSON_NULL = 10;
pub let BSON_REGEX = 11;
pub let BSON_INT32 = 16;
pub let BSON_TIMESTAMP = 17;
pub let BSON_INT64 = 18;
pub let BSON_DECIMAL128 = 19;
pub let BSON_MIN_KEY = 255;
pub let BSON_MAX_KEY = 127;

pub let DEFAULT_MAX_BSON_BYTES = 16777216;
pub let DEFAULT_MAX_BSON_DEPTH = 100;
pub let DEFAULT_MAX_BSON_VALUES = 100000;

// Only the payload slot selected by kind is meaningful. The codec checks
// mutable values again before writing them to the wire.
pub gc struct Value {
    kind: int,
    bool_value: bool,
    int_value: int,
    uint_value: u64,
    float_value: float,
    text: str,
    aux: str,
    data: bytes,
    document: opt[Document],
    items: [Value],
    subtype: int,
}

pub gc struct Document {
    fields: [Field],
}

pub struct Field {
    key: str,
    value: Value,
}

pub gc struct Limits {
    max_document_bytes: int,
    max_depth: int,
    max_values: int,
}

// Heap-backed traversal state keeps arbitrary BSON nesting off the 8 KB
// task stack.
gc struct EncodeFrame {
    source: Value,
    index: int,
    depth: int,
    parent_key: str,
    parent_type: int,
    out: builder.Bytes,
}

gc struct DecodeFrame {
    document: Document,
    array_values: [Value],
    array: bool,
    pos: int,
    end: int,
    depth: int,
    next_array_index: int,
    parent_key: str,
    parent_type: int,
}

pub fn document() -> Document {
    let fields: [Field] = [];
    return Document { fields: fields };
}

pub fn document_len(doc: Document) -> int {
    return len(doc.fields);
}

pub fn put(doc: Document, key: str, value: Value) -> result[bool, str] {
    let raw = to_bytes(key);
    if bson_has_zero(raw) {
        return err("bson.put: field name contains NUL");
    }
    if !bson_valid_utf8(raw, 0, len(raw)) {
        return err("bson.put: field name is not valid UTF-8");
    }
    let existing = bson_find_field(doc, key);
    if existing >= 0 {
        doc.fields[existing] = Field { key: key, value: value };
        return ok(true);
    }
    push(doc.fields, Field { key: key, value: value });
    return ok(true);
}

pub fn get(doc: Document, key: str) -> opt[Value] {
    let i = bson_find_field(doc, key);
    if i < 0 {
        return none;
    }
    return some(doc.fields[i].value);
}

pub fn has_field(doc: Document, key: str) -> bool {
    return bson_find_field(doc, key) >= 0;
}

fn bson_find_field(doc: Document, key: str) -> int {
    let i = 0;
    while i < len(doc.fields) {
        if doc.fields[i].key == key {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn bson_empty_value(kind: int) -> Value {
    let no_document: opt[Document] = none;
    let no_items: [Value] = [];
    return Value {
        kind: kind,
        bool_value: false,
        int_value: 0,
        uint_value: 0,
        float_value: 0.0,
        text: "",
        aux: "",
        data: b"",
        document: no_document,
        items: no_items,
        subtype: 0
    };
}

pub fn null_value() -> Value {
    return bson_empty_value(BSON_NULL);
}

pub fn bool_value(value: bool) -> Value {
    let out = bson_empty_value(BSON_BOOL);
    out.bool_value = value;
    return out;
}

pub fn int32_value(value: int) -> result[Value, str] {
    if value < -2147483648 || value > 2147483647 {
        return err("bson.int32_value: value is outside the int32 range");
    }
    let out = bson_empty_value(BSON_INT32);
    out.int_value = value;
    return ok(out);
}

pub fn int64_value(value: int) -> Value {
    let out = bson_empty_value(BSON_INT64);
    out.int_value = value;
    return out;
}

pub fn double_value(value: float) -> Value {
    let out = bson_empty_value(BSON_DOUBLE);
    out.float_value = value;
    return out;
}

pub fn string_value(value: str) -> Value {
    let out = bson_empty_value(BSON_STRING);
    out.data = to_bytes(value);
    return out;
}

// BSON strings can contain U+0000, while slang str is NUL-terminated.
// Preserve such strings as bytes; as_string reports an error rather than
// silently truncating them.
pub fn string_bytes_value(raw: bytes) -> result[Value, str] {
    if !bson_valid_utf8(raw, 0, len(raw)) {
        return err("bson.string_bytes_value: bytes are not valid UTF-8");
    }
    let out = bson_empty_value(BSON_STRING);
    out.data = bson_copy_bytes(raw);
    out.subtype = 1;
    return ok(out);
}

// Decoder-owned slices are already detached from the input buffer. Marking
// them validated lets as_string avoid scanning their bytes a second time.
fn bson_string_value_validated(data: bytes) -> Value {
    let out = bson_empty_value(BSON_STRING);
    out.data = data;
    out.subtype = 1;
    return out;
}

fn bson_string_value_text_validated(value: str) -> Value {
    let out = bson_empty_value(BSON_STRING);
    out.text = value;
    out.subtype = 2;
    return out;
}

fn bson_string_bytes(value: Value) -> bytes {
    if value.subtype == 2 {
        return to_bytes(value.text);
    }
    return value.data;
}

pub fn binary_value(raw: bytes, subtype: int) -> result[Value, str] {
    if subtype < 0 || subtype > 255 {
        return err("bson.binary_value: subtype must be in range 0 to 255");
    }
    let out = bson_empty_value(BSON_BINARY);
    out.data = bson_copy_bytes(raw);
    out.subtype = subtype;
    return ok(out);
}

pub fn object_id_value(raw: bytes) -> result[Value, str] {
    if len(raw) != 12 {
        return err("bson.object_id_value: ObjectId must be exactly 12 bytes");
    }
    let out = bson_empty_value(BSON_OBJECT_ID);
    out.data = bson_copy_bytes(raw);
    return ok(out);
}

pub fn decimal128_value(raw: bytes) -> result[Value, str] {
    if len(raw) != 16 {
        return err("bson.decimal128_value: Decimal128 must be exactly 16 bytes");
    }
    let out = bson_empty_value(BSON_DECIMAL128);
    out.data = bson_copy_bytes(raw);
    return ok(out);
}

pub fn datetime_value(milliseconds: int) -> Value {
    let out = bson_empty_value(BSON_DATETIME);
    out.int_value = milliseconds;
    return out;
}

// Timestamp keeps the BSON 64-bit bit pattern. timestamp_parts builds the
// seconds/increment representation without signed overflow.
pub fn timestamp_value(raw_bits: u64) -> Value {
    let out = bson_empty_value(BSON_TIMESTAMP);
    out.uint_value = raw_bits;
    return out;
}

pub fn timestamp_parts(seconds: int, increment: int) -> result[Value, str] {
    if seconds < 0 || seconds > 4294967295 ||
       increment < 0 || increment > 4294967295 {
        return err("bson.timestamp_parts: components must fit uint32");
    }
    let sec: u64 = seconds as u64;
    let inc: u64 = increment as u64;
    let factor: u64 = 4294967296;
    let raw = sec * factor + inc;
    return ok(timestamp_value(raw));
}

pub fn regex_value(pattern: str, options: str) -> result[Value, str] {
    let p = to_bytes(pattern);
    let o = to_bytes(options);
    if bson_has_zero(p) || bson_has_zero(o) {
        return err("bson.regex_value: pattern and options cannot contain NUL");
    }
    if !bson_valid_utf8(p, 0, len(p)) || !bson_valid_utf8(o, 0, len(o)) {
        return err("bson.regex_value: pattern and options must be valid UTF-8");
    }
    let out = bson_empty_value(BSON_REGEX);
    out.text = pattern;
    out.aux = options;
    return ok(out);
}

pub fn document_value(value: Document) -> Value {
    let out = bson_empty_value(BSON_DOCUMENT);
    out.document = some(value);
    return out;
}

pub fn array_value(values: [Value]) -> Value {
    let copied: [Value] = [];
    let i = 0;
    while i < len(values) {
        push(copied, values[i]);
        i = i + 1;
    }
    let out = bson_empty_value(BSON_ARRAY);
    out.items = copied;
    return out;
}

fn bson_array_value_owned(values: [Value]) -> Value {
    let out = bson_empty_value(BSON_ARRAY);
    out.items = values;
    return out;
}

pub fn min_key_value() -> Value {
    return bson_empty_value(BSON_MIN_KEY);
}

pub fn max_key_value() -> Value {
    return bson_empty_value(BSON_MAX_KEY);
}

pub fn as_string(value: Value) -> result[str, str] {
    if value.kind != BSON_STRING {
        return err("bson.as_string: value is not a BSON string");
    }
    if value.subtype == 2 {
        return ok(value.text);
    }
    if bson_has_zero(value.data) {
        return err("bson.as_string: BSON string contains U+0000; use as_string_bytes");
    }
    if value.subtype != 1 &&
       !bson_valid_utf8(value.data, 0, len(value.data)) {
        return err("bson.as_string: BSON string is not valid UTF-8");
    }
    return ok(to_str(value.data));
}

pub fn as_string_bytes(value: Value) -> result[bytes, str] {
    if value.kind != BSON_STRING {
        return err("bson.as_string_bytes: value is not a BSON string");
    }
    if value.subtype == 2 {
        return ok(to_bytes(value.text));
    }
    return ok(bson_copy_bytes(value.data));
}

pub fn as_bool(value: Value) -> result[bool, str] {
    if value.kind != BSON_BOOL {
        return err("bson.as_bool: value is not a BSON boolean");
    }
    return ok(value.bool_value);
}

pub fn as_int(value: Value) -> result[int, str] {
    if value.kind != BSON_INT32 && value.kind != BSON_INT64 &&
       value.kind != BSON_DATETIME {
        return err("bson.as_int: value is not a BSON integer or date");
    }
    return ok(value.int_value);
}

pub fn as_int32(value: Value) -> result[int, str] {
    if value.kind != BSON_INT32 {
        return err("bson.as_int32: value is not a BSON int32");
    }
    return ok(value.int_value);
}

pub fn as_int64(value: Value) -> result[int, str] {
    if value.kind != BSON_INT64 {
        return err("bson.as_int64: value is not a BSON int64");
    }
    return ok(value.int_value);
}

pub fn as_datetime(value: Value) -> result[int, str] {
    if value.kind != BSON_DATETIME {
        return err("bson.as_datetime: value is not a BSON DateTime");
    }
    return ok(value.int_value);
}

pub fn as_timestamp_bits(value: Value) -> result[u64, str] {
    if value.kind != BSON_TIMESTAMP {
        return err("bson.as_timestamp_bits: value is not a BSON timestamp");
    }
    return ok(value.uint_value);
}

pub fn as_double(value: Value) -> result[float, str] {
    if value.kind != BSON_DOUBLE {
        return err("bson.as_double: value is not a BSON double");
    }
    return ok(value.float_value);
}

pub fn as_document(value: Value) -> result[Document, str] {
    if value.kind != BSON_DOCUMENT {
        return err("bson.as_document: value is not a BSON document");
    }
    guard let doc = value.document else {
        return err("bson.as_document: missing document payload");
    }
    return ok(doc);
}

pub fn as_array(value: Value) -> result[[Value], str] {
    if value.kind != BSON_ARRAY {
        return err("bson.as_array: value is not a BSON array");
    }
    let out: [Value] = [];
    let i = 0;
    while i < len(value.items) {
        push(out, value.items[i]);
        i = i + 1;
    }
    return ok(out);
}

pub fn as_binary(value: Value) -> result[bytes, str] {
    if value.kind != BSON_BINARY {
        return err("bson.as_binary: value is not BSON binary data");
    }
    return ok(bson_copy_bytes(value.data));
}

pub fn binary_subtype(value: Value) -> result[int, str] {
    if value.kind != BSON_BINARY {
        return err("bson.binary_subtype: value is not BSON binary data");
    }
    return ok(value.subtype);
}

pub fn as_object_id(value: Value) -> result[bytes, str] {
    if value.kind != BSON_OBJECT_ID {
        return err("bson.as_object_id: value is not a BSON ObjectId");
    }
    return ok(bson_copy_bytes(value.data));
}

pub fn as_decimal128(value: Value) -> result[bytes, str] {
    if value.kind != BSON_DECIMAL128 {
        return err("bson.as_decimal128: value is not a BSON Decimal128");
    }
    return ok(bson_copy_bytes(value.data));
}

pub fn default_limits() -> Limits {
    return Limits {
        max_document_bytes: DEFAULT_MAX_BSON_BYTES,
        max_depth: DEFAULT_MAX_BSON_DEPTH,
        max_values: DEFAULT_MAX_BSON_VALUES
    };
}

pub fn new_limits(max_document_bytes: int, max_depth: int,
                  max_values: int) -> result[Limits, str] {
    if max_document_bytes < 5 || max_document_bytes > 2147483647 {
        return err("bson.new_limits: max_document_bytes must be 5 to 2147483647");
    }
    if max_depth < 1 || max_depth > 100000 {
        return err("bson.new_limits: max_depth must be 1 to 100000");
    }
    if max_values < 1 || max_values > 2147483647 {
        return err("bson.new_limits: max_values must be 1 to 2147483647");
    }
    return ok(Limits {
        max_document_bytes: max_document_bytes,
        max_depth: max_depth,
        max_values: max_values
    });
}

fn bson_limits_valid(limits: Limits) -> bool {
    return limits.max_document_bytes >= 5 &&
           limits.max_document_bytes <= 2147483647 &&
           limits.max_depth >= 1 && limits.max_depth <= 100000 &&
           limits.max_values >= 1 && limits.max_values <= 2147483647;
}

fn bson_copy_bytes(raw: bytes) -> bytes {
    let out = builder.new_bytes();
    out.write(raw);
    return out.finish();
}

fn bson_has_zero(raw: bytes) -> bool {
    let i = 0;
    while i < len(raw) {
        if raw[i] == 0 {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// Strict UTF-8 validation: reject overlong forms, surrogate encodings,
// invalid continuation bytes, and code points above U+10FFFF.
fn bson_valid_utf8(raw: bytes, start: int, end: int) -> bool {
    if start < 0 || end < start || end > len(raw) {
        return false;
    }
    let i = start;
    while i < end {
        let a = raw[i];
        if a <= 127 {
            i = i + 1;
        } else if a >= 194 && a <= 223 {
            if end - i < 2 || raw[i + 1] < 128 || raw[i + 1] > 191 {
                return false;
            }
            i = i + 2;
        } else if a == 224 {
            if end - i < 3 || raw[i + 1] < 160 || raw[i + 1] > 191 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 {
                return false;
            }
            i = i + 3;
        } else if (a >= 225 && a <= 236) || (a >= 238 && a <= 239) {
            if end - i < 3 || raw[i + 1] < 128 || raw[i + 1] > 191 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 {
                return false;
            }
            i = i + 3;
        } else if a == 237 {
            if end - i < 3 || raw[i + 1] < 128 || raw[i + 1] > 159 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 {
                return false;
            }
            i = i + 3;
        } else if a == 240 {
            if end - i < 4 || raw[i + 1] < 144 || raw[i + 1] > 191 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 ||
               raw[i + 3] < 128 || raw[i + 3] > 191 {
                return false;
            }
            i = i + 4;
        } else if a >= 241 && a <= 243 {
            if end - i < 4 || raw[i + 1] < 128 || raw[i + 1] > 191 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 ||
               raw[i + 3] < 128 || raw[i + 3] > 191 {
                return false;
            }
            i = i + 4;
        } else if a == 244 {
            if end - i < 4 || raw[i + 1] < 128 || raw[i + 1] > 143 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 ||
               raw[i + 3] < 128 || raw[i + 3] > 191 {
                return false;
            }
            i = i + 4;
        } else {
            return false;
        }
    }
    return true;
}
