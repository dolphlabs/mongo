import "strings";
import "encoding";

// A view owns a reference to the immutable input bytes through a private
// storage object. Callers can copy a view without copying the BSON payload.
gc struct BsonDocumentViewData {
    raw: bytes,
    start: int,
    end: int
}

gc struct BsonValueViewData {
    raw: bytes,
    kind: int,
    start: int,
    end: int
}

// A read-only handle to a validated BSON document backed by its original
// bytes. Copying the view does not copy the document. Do not mutate the source
// bytes while this view or one of its values is in use.
pub struct DocumentView {
    inner: BsonDocumentViewData
}

// A read-only handle to a BSON value range backed by its document's original
// bytes. Keeping the view alive keeps those bytes alive; do not mutate them.
pub struct ValueView {
    inner: BsonValueViewData
}

struct BsonViewKey {
    start: int,
    end: int
}

gc struct BsonViewFrame {
    start: int,
    end: int,
    pos: int,
    depth: int,
    array: bool,
    next_index: int,
    parent_type: int,
    keys: [BsonViewKey]
}

// A view of one complete BSON document, or an error if the input is malformed
// or exceeds `default_limits()`. Every value is validated, including fields
// never accessed. The view retains `raw` without copying its BSON bytes; do
// not mutate `raw` while this view or a derived value view is in use.
pub fn decode_view(raw: bytes) -> result[DocumentView, str] {
    return decode_view_with_limits(raw, default_limits());
}

// A view of one complete BSON document under `limits`, or an error if the
// input or limits are invalid. Every value is validated, including fields
// never accessed. The view retains `raw` without copying its BSON bytes; do
// not mutate `raw` while this view or a derived value view is in use.
pub fn decode_view_with_limits(raw: bytes, limits: Limits)
                               -> result[DocumentView, str] {
    if !bson_limits_valid(limits) {
        return err("bson.decode_view: invalid limits");
    }
    if len(raw) < 5 {
        return err("bson.decode_view: document is shorter than its header and terminator");
    }
    if len(raw) > limits.max_document_bytes {
        return err("bson.decode_view: document exceeds configured byte limit");
    }
    let size = bson_read_i32(raw, 0);
    if size != len(raw) {
        return err("bson.decode_view: declared document length does not match the input size");
    }
    let checked = bson_view_validate_at(raw, 0, size, limits);
    guard let _valid = checked else let e = err_of(checked) { return err(e); }
    return ok(bson_view_make_document(raw, 0, size));
}

fn bson_view_decode_at(raw: bytes, start: int, size: int, limits: Limits)
                       -> result[DocumentView, str] {
    if !bson_limits_valid(limits) {
        return err("mongo.command protocol: invalid BSON view limits");
    }
    if size < 5 || size > limits.max_document_bytes || start < 0 ||
       start > len(raw) || size > len(raw) - start {
        return err("mongo.command protocol: BSON view range is outside configured bounds");
    }
    if bson_read_i32(raw, start) != size {
        return err("mongo.command protocol: BSON view length does not match its range");
    }
    let checked = bson_view_validate_at(raw, start, size, limits);
    guard let _valid = checked else let e = err_of(checked) {
        return err("mongo.command protocol: invalid BSON response: " + e);
    }
    return ok(bson_view_make_document(raw, start, start + size));
}

fn bson_view_make_document(raw: bytes, start: int, end: int) -> DocumentView {
    return DocumentView {
        inner: BsonDocumentViewData { raw: raw, start: start, end: end }
    };
}

fn bson_view_make_value(raw: bytes, kind: int, start: int, end: int)
                       -> ValueView {
    return ValueView {
        inner: BsonValueViewData {
            raw: raw, kind: kind, start: start, end: end
        }
    };
}

fn bson_view_raw(view: DocumentView) -> bytes {
    return view.inner.raw;
}

fn bson_view_start(view: DocumentView) -> int {
    return view.inner.start;
}

fn bson_view_end(view: DocumentView) -> int {
    return view.inner.end;
}

fn bson_value_view_raw(view: ValueView) -> bytes {
    return view.inner.raw;
}

fn bson_value_view_kind(view: ValueView) -> int {
    return view.inner.kind;
}

fn bson_value_view_start(view: ValueView) -> int {
    return view.inner.start;
}

fn bson_value_view_end(view: ValueView) -> int {
    return view.inner.end;
}

// Iterative validation keeps arbitrary nested documents off the task stack.
fn bson_view_validate_at(raw: bytes, start: int, size: int, limits: Limits)
                         -> result[bool, str] {
    if start < 0 || start > len(raw) || size < 5 || size > len(raw) - start ||
       bson_read_i32(raw, start) != size {
        return err("bson.decode_view: invalid document boundary");
    }
    let frames: [BsonViewFrame] = [];
    let keys: [BsonViewKey] = [];
    push(frames, BsonViewFrame {
        start: start,
        end: start + size,
        pos: start + 4,
        depth: 1,
        array: false,
        next_index: 0,
        parent_type: 0,
        keys: keys
    });
    let values = 0;

    while len(frames) > 0 {
        let frame = frames[len(frames) - 1];
        let terminal = frame.end - 1;
        if frame.pos == terminal {
            if raw[terminal] != 0 {
                return err("bson.decode_view: missing document terminator");
            }
            let child = pop(frames);
            if len(frames) == 0 {
                return ok(true);
            }
            let parent = frames[len(frames) - 1];
            parent.pos = child.end;
            if parent.array {
                parent.next_index = parent.next_index + 1;
            }
            continue;
        }
        if frame.pos > terminal {
            return err("bson.decode_view: element passes the document boundary");
        }

        values = values + 1;
        if values > limits.max_values {
            return err("bson.decode_view: value count exceeds configured limit");
        }
        let kind = raw[frame.pos];
        if kind == 0 {
            return err("bson.decode_view: early document terminator");
        }
        let key_start = frame.pos + 1;
        let key_end_result = bson_view_cstring_end(raw, key_start, terminal);
        guard let key_end = key_end_result else let e = err_of(key_end_result) {
            return err("bson.decode_view: " + e);
        }
        if frame.array {
            if !bson_view_index_matches(raw, key_start, key_end,
                                        frame.next_index) {
                return err("bson.decode_view: array index is not the expected " +
                           to_str(frame.next_index));
            }
        } else {
            let i = 0;
            while i < len(frame.keys) {
                let prior = frame.keys[i];
                if prior.end - prior.start == key_end - key_start {
                    let same = true;
                    let j = 0;
                    while j < key_end - key_start {
                        if raw[prior.start + j] != raw[key_start + j] {
                            same = false;
                            break;
                        }
                        j = j + 1;
                    }
                    if same {
                        return err("bson.decode_view: duplicate field name " +
                                   strings.from_bytes(raw, key_start, key_end));
                    }
                }
                i = i + 1;
            }
            push(frame.keys, BsonViewKey { start: key_start, end: key_end });
        }

        let value_start = key_end + 1;
        if kind == BSON_DOCUMENT || kind == BSON_ARRAY {
            if value_start > terminal || 4 > terminal - value_start {
                return err("bson.decode_view: truncated nested document length");
            }
            let nested_size = bson_read_i32(raw, value_start);
            if nested_size < 5 || nested_size > limits.max_document_bytes ||
               nested_size > terminal - value_start {
                return err("bson.decode_view: invalid or out-of-bounds nested document");
            }
            if frame.depth >= limits.max_depth {
                return err("bson.decode_view: nesting depth exceeds configured limit");
            }
            let child_keys: [BsonViewKey] = [];
            push(frames, BsonViewFrame {
                start: value_start,
                end: value_start + nested_size,
                pos: value_start + 4,
                depth: frame.depth + 1,
                array: kind == BSON_ARRAY,
                next_index: 0,
                parent_type: kind,
                keys: child_keys
            });
            continue;
        }

        let next_result = bson_view_skip_scalar(raw, value_start, terminal,
                                                kind);
        guard let next = next_result else let e = err_of(next_result) {
            return err(e);
        }
        frame.pos = next;
        if frame.array {
            frame.next_index = frame.next_index + 1;
        }
    }
    return err("bson.decode_view: internal traversal ended without a document");
}

fn bson_view_cstring_end(raw: bytes, start: int, end: int)
                        -> result[int, str] {
    if start < 0 || end < start || end > len(raw) {
        return err("invalid cstring boundary");
    }
    let i = start;
    while i < end && raw[i] != 0 {
        i = i + 1;
    }
    if i >= end {
        return err("unterminated cstring");
    }
    if !bson_valid_utf8(raw, start, i) {
        return err("cstring is not valid UTF-8");
    }
    return ok(i);
}

fn bson_view_index_matches(raw: bytes, start: int, end: int, index: int)
                           -> bool {
    if index < 0 || start < 0 || end < start || end > len(raw) {
        return false;
    }
    let digits = 1;
    let remaining = index;
    while remaining >= 10 {
        remaining = remaining / 10;
        digits = digits + 1;
    }
    if end - start != digits {
        return false;
    }
    let i = end - 1;
    remaining = index;
    while i >= start {
        if raw[i] != 48 + remaining % 10 {
            return false;
        }
        remaining = remaining / 10;
        i = i - 1;
    }
    return true;
}

fn bson_view_skip_scalar(raw: bytes, pos: int, end: int, kind: int)
                        -> result[int, str] {
    if kind == BSON_DOUBLE {
        if !bson_has_range(raw, pos, 8, end) {
            return err("bson.decode_view: truncated double");
        }
        let decoded = encoding.float64_from_le(raw[pos..pos + 8]);
        guard let _number = decoded else let e = err_of(decoded) {
            return err("bson.decode_view: invalid double: " + e);
        }
        return ok(pos + 8);
    }
    if kind == BSON_STRING {
        if !bson_has_range(raw, pos, 4, end) {
            return err("bson.decode_view: truncated string length");
        }
        let size = bson_read_i32(raw, pos);
        if size < 1 || !bson_has_range(raw, pos + 4, size, end) {
            return err("bson.decode_view: invalid or truncated string");
        }
        let data_start = pos + 4;
        let terminator = data_start + size - 1;
        if raw[terminator] != 0 {
            return err("bson.decode_view: string has no trailing NUL");
        }
        if !bson_valid_utf8(raw, data_start, terminator) {
            return err("bson.decode_view: string value is not valid UTF-8");
        }
        return ok(terminator + 1);
    }
    if kind == BSON_BINARY {
        if !bson_has_range(raw, pos, 5, end) {
            return err("bson.decode_view: truncated binary header");
        }
        let size = bson_read_i32(raw, pos);
        if size < 0 || !bson_has_range(raw, pos + 5, size, end) {
            return err("bson.decode_view: invalid or truncated binary payload");
        }
        if raw[pos + 4] == 2 {
            if size < 4 || bson_read_i32(raw, pos + 5) != size - 4 {
                return err("bson.decode_view: invalid legacy binary length");
            }
        }
        return ok(pos + 5 + size);
    }
    if kind == BSON_OBJECT_ID {
        if !bson_has_range(raw, pos, 12, end) {
            return err("bson.decode_view: truncated ObjectId");
        }
        return ok(pos + 12);
    }
    if kind == BSON_BOOL {
        if !bson_has_range(raw, pos, 1, end) {
            return err("bson.decode_view: truncated boolean");
        }
        if raw[pos] > 1 {
            return err("bson.decode_view: boolean byte must be 0 or 1");
        }
        return ok(pos + 1);
    }
    if kind == BSON_DATETIME || kind == BSON_INT64 || kind == BSON_TIMESTAMP {
        if !bson_has_range(raw, pos, 8, end) {
            return err("bson.decode_view: truncated 64-bit value");
        }
        return ok(pos + 8);
    }
    if kind == BSON_INT32 {
        if !bson_has_range(raw, pos, 4, end) {
            return err("bson.decode_view: truncated int32");
        }
        return ok(pos + 4);
    }
    if kind == BSON_DECIMAL128 {
        if !bson_has_range(raw, pos, 16, end) {
            return err("bson.decode_view: truncated Decimal128");
        }
        return ok(pos + 16);
    }
    if kind == BSON_REGEX {
        let pattern = bson_view_cstring_end(raw, pos, end);
        guard let pattern_end = pattern else let e = err_of(pattern) {
            return err("bson.decode_view: invalid regex pattern: " + e);
        }
        let options = bson_view_cstring_end(raw, pattern_end + 1, end);
        guard let options_end = options else let e = err_of(options) {
            return err("bson.decode_view: invalid regex options: " + e);
        }
        let i = pattern_end + 1;
        while i < options_end {
            if raw[i] == 0 {
                return err("bson.decode_view: regex options contain NUL");
            }
            i = i + 1;
        }
        return ok(options_end + 1);
    }
    if kind == BSON_NULL || kind == BSON_MIN_KEY || kind == BSON_MAX_KEY {
        return ok(pos);
    }
    return err("bson.decode_view: unsupported BSON type tag " + to_str(kind));
}

// The field named `key`, or `ok(none)` when it is absent. Invalid views and
// keys containing NUL or invalid UTF-8 return an error. BSON duplicate keys
// are rejected when the view is created.
pub fn view_get(doc: DocumentView, key: str) -> result[opt[ValueView], str] {
    let raw = bson_view_raw(doc);
    let start = bson_view_start(doc);
    let end = bson_view_end(doc);
    if start < 0 || end < start || end > len(raw) || end - start < 5 ||
       bson_read_i32(raw, start) != end - start || raw[end - 1] != 0 {
        return err("bson.view_get: invalid document view");
    }
    let key_bytes = to_bytes(key);
    if bson_has_zero(key_bytes) ||
       !bson_valid_utf8(key_bytes, 0, len(key_bytes)) {
        return err("bson.view_get: key must be valid UTF-8 without NUL");
    }
    let pos = start + 4;
    let terminal = end - 1;
    while pos < terminal {
        let kind = raw[pos];
        let key_start = pos + 1;
        let key_end_result = bson_view_cstring_end(raw, key_start, terminal);
        guard let key_end = key_end_result else let e = err_of(key_end_result) {
            return err("bson.view_get: " + e);
        }
        let value_start = key_end + 1;
        let next_result = bson_view_value_end_trusted(raw, value_start,
                                                       terminal, kind);
        guard let next = next_result else let e = err_of(next_result) {
            return err("bson.view_get: " + e);
        }
        if bson_view_key_equals(raw, key_start, key_end, key_bytes) {
            return ok(some(bson_view_make_value(raw, kind, value_start, next)));
        }
        pos = next;
    }
    return ok(none);
}

fn bson_view_key_equals(raw: bytes, start: int, end: int, key: bytes) -> bool {
    if end - start != len(key) {
        return false;
    }
    let i = 0;
    while i < len(key) {
        if raw[start + i] != key[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn bson_view_value_end(raw: bytes, pos: int, end: int, kind: int)
                       -> result[int, str] {
    if kind == BSON_DOCUMENT || kind == BSON_ARRAY {
        if !bson_has_range(raw, pos, 4, end) {
            return err("truncated nested document length");
        }
        let size = bson_read_i32(raw, pos);
        if size < 5 || !bson_has_range(raw, pos, size, end) ||
           raw[pos + size - 1] != 0 {
            return err("invalid nested document boundary");
        }
        return ok(pos + size);
    }
    return bson_view_skip_scalar(raw, pos, end, kind);
}

// View construction validates every value once. Field lookup only needs safe
// lengths to skip unrelated values; re-validating their payloads would turn a
// selective read into repeated UTF-8 scans.
fn bson_view_value_end_trusted(raw: bytes, pos: int, end: int, kind: int)
                              -> result[int, str] {
    if kind == BSON_DOCUMENT || kind == BSON_ARRAY {
        if !bson_has_range(raw, pos, 4, end) {
            return err("truncated nested document length");
        }
        let size = bson_read_i32(raw, pos);
        if size < 5 || !bson_has_range(raw, pos, size, end) ||
           raw[pos + size - 1] != 0 {
            return err("invalid nested document boundary");
        }
        return ok(pos + size);
    }
    if kind == BSON_DOUBLE || kind == BSON_DATETIME ||
       kind == BSON_INT64 || kind == BSON_TIMESTAMP {
        if !bson_has_range(raw, pos, 8, end) {
            return err("truncated 64-bit BSON value");
        }
        return ok(pos + 8);
    }
    if kind == BSON_INT32 {
        if !bson_has_range(raw, pos, 4, end) {
            return err("truncated int32");
        }
        return ok(pos + 4);
    }
    if kind == BSON_STRING {
        if !bson_has_range(raw, pos, 4, end) {
            return err("truncated string length");
        }
        let size = bson_read_i32(raw, pos);
        if size < 1 || !bson_has_range(raw, pos + 4, size, end) ||
           raw[pos + 4 + size - 1] != 0 {
            return err("invalid string boundary");
        }
        return ok(pos + 4 + size);
    }
    if kind == BSON_BINARY {
        if !bson_has_range(raw, pos, 5, end) {
            return err("truncated binary header");
        }
        let size = bson_read_i32(raw, pos);
        if size < 0 || !bson_has_range(raw, pos + 5, size, end) {
            return err("invalid binary boundary");
        }
        return ok(pos + 5 + size);
    }
    if kind == BSON_OBJECT_ID || kind == BSON_DECIMAL128 {
        let size = 12;
        if kind == BSON_DECIMAL128 { size = 16; }
        if !bson_has_range(raw, pos, size, end) {
            return err("truncated fixed-size BSON value");
        }
        return ok(pos + size);
    }
    if kind == BSON_BOOL {
        if !bson_has_range(raw, pos, 1, end) {
            return err("truncated boolean");
        }
        return ok(pos + 1);
    }
    if kind == BSON_REGEX {
        let pattern = pos;
        while pattern < end && raw[pattern] != 0 { pattern = pattern + 1; }
        if pattern >= end { return err("unterminated regex pattern"); }
        let options = pattern + 1;
        while options < end && raw[options] != 0 { options = options + 1; }
        if options >= end { return err("unterminated regex options"); }
        return ok(options + 1);
    }
    if kind == BSON_NULL || kind == BSON_MIN_KEY || kind == BSON_MAX_KEY {
        return ok(pos);
    }
    return err("unsupported BSON type tag " + to_str(kind));
}

// The BSON wire type tag for `value`; compare it with the `BSON_*` constants.
pub fn view_kind(value: ValueView) -> int {
    return bson_value_view_kind(value);
}

// The value as `int` when it is BSON Int32, Int64, or DateTime milliseconds.
// Other types return an error; no numeric coercion is performed.
pub fn view_as_int(value: ValueView) -> result[int, str] {
    let raw = bson_value_view_raw(value);
    let kind = bson_value_view_kind(value);
    let pos = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    if kind == BSON_INT32 {
        if !bson_has_range(raw, pos, 4, end) {
            return err("bson.view_as_int: truncated int32");
        }
        return ok(bson_read_i32(raw, pos));
    }
    if kind == BSON_INT64 || kind == BSON_DATETIME {
        if !bson_has_range(raw, pos, 8, end) {
            return err("bson.view_as_int: truncated 64-bit value");
        }
        return ok(bson_read_i64(raw, pos));
    }
    return err("bson.view_as_int: value is not a BSON integer or date");
}

// The value as `bool` when it is a valid BSON Boolean; other types return an
// error.
pub fn view_as_bool(value: ValueView) -> result[bool, str] {
    let raw = bson_value_view_raw(value);
    let pos = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    if bson_value_view_kind(value) != BSON_BOOL {
        return err("bson.view_as_bool: value is not a BSON boolean");
    }
    if !bson_has_range(raw, pos, 1, end) || raw[pos] > 1 {
        return err("bson.view_as_bool: invalid BSON boolean");
    }
    return ok(raw[pos] == 1);
}

// The value as an IEEE-754 `float` when it is BSON Double; other types return
// an error.
pub fn view_as_double(value: ValueView) -> result[float, str] {
    let raw = bson_value_view_raw(value);
    let pos = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    if bson_value_view_kind(value) != BSON_DOUBLE {
        return err("bson.view_as_double: value is not a BSON double");
    }
    if !bson_has_range(raw, pos, 8, end) {
        return err("bson.view_as_double: truncated double");
    }
    return encoding.float64_from_le(raw[pos..pos + 8]);
}

// The UTF-8 byte length of a BSON string, excluding its trailing NUL. Other
// types return an error. This reads the length without allocating a slang
// `str`.
pub fn view_string_len(value: ValueView) -> result[int, str] {
    let raw = bson_value_view_raw(value);
    let pos = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    if bson_value_view_kind(value) != BSON_STRING {
        return err("bson.view_string_len: value is not a BSON string");
    }
    if !bson_has_range(raw, pos, 4, end) {
        return err("bson.view_string_len: truncated string length");
    }
    let size = bson_read_i32(raw, pos);
    if size < 1 || !bson_has_range(raw, pos + 4, size, end) ||
       raw[pos + 4 + size - 1] != 0 {
        return err("bson.view_string_len: invalid BSON string boundary");
    }
    return ok(size - 1);
}

// The value as a newly materialized slang `str` when it is a BSON string.
// Strings containing U+0000 return an error because slang `str` is
// NUL-terminated; use `view_string_len` when only the encoded byte length is
// needed.
pub fn view_as_string(value: ValueView) -> result[str, str] {
    let raw = bson_value_view_raw(value);
    let pos = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    let size_result = view_string_len(value);
    guard let size = size_result else let e = err_of(size_result) { return err(e); }
    let start = pos + 4;
    let i = start;
    while i < start + size {
        if raw[i] == 0 {
            return err("bson.view_as_string: BSON string contains U+0000; use decode and as_string_bytes");
        }
        i = i + 1;
    }
    return ok(strings.from_bytes(raw, start, start + size));
}

// A nested `DocumentView` when the value is a BSON document. BSON arrays and
// all other types return an error.
pub fn view_as_document(value: ValueView) -> result[DocumentView, str] {
    let raw = bson_value_view_raw(value);
    let start = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    if bson_value_view_kind(value) != BSON_DOCUMENT {
        return err("bson.view_as_document: value is not a BSON document");
    }
    if start < 0 || end < start || end > len(raw) || end - start < 5 ||
       bson_read_i32(raw, start) != end - start || raw[end - 1] != 0 {
        return err("bson.view_as_document: invalid nested BSON document");
    }
    return ok(bson_view_make_document(raw, start, end));
}

// A copy of the BSON binary payload, without its subtype byte. Legacy subtype
// 2's inner length prefix is removed. The subtype is not returned by this API.
pub fn view_as_binary(value: ValueView) -> result[bytes, str] {
    let raw = bson_value_view_raw(value);
    let pos = bson_value_view_start(value);
    let end = bson_value_view_end(value);
    if bson_value_view_kind(value) != BSON_BINARY {
        return err("bson.view_as_binary: value is not BSON binary");
    }
    if !bson_has_range(raw, pos, 5, end) {
        return err("bson.view_as_binary: truncated binary header");
    }
    let size = bson_read_i32(raw, pos);
    if size < 0 || !bson_has_range(raw, pos + 5, size, end) {
        return err("bson.view_as_binary: invalid binary boundary");
    }
    let data_start = pos + 5;
    let data_len = size;
    if raw[pos + 4] == 2 {
        if size < 4 || bson_read_i32(raw, pos + 5) != size - 4 {
            return err("bson.view_as_binary: invalid legacy binary length");
        }
        data_start = pos + 9;
        data_len = size - 4;
    }
    return ok(raw[data_start..data_start + data_len]);
}
