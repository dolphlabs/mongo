struct DecodedBsonValue {
    value: Value,
    next: int,
}

struct BsonCString {
    raw: bytes,
    next: int,
}

pub fn decode(raw: bytes) -> result[Document, str] {
    return decode_with_limits(raw, default_limits());
}

pub fn decode_with_limits(raw: bytes, limits: Limits)
                          -> result[Document, str] {
    if !bson_limits_valid(limits) {
        return err("bson.decode: invalid limits");
    }
    if len(raw) < 5 {
        return err("bson.decode: document is shorter than its header and terminator");
    }
    if len(raw) > limits.max_document_bytes {
        return err("bson.decode: document exceeds configured byte limit");
    }
    let root_len = bson_read_i32(raw, 0);
    if root_len != len(raw) {
        return err("bson.decode: declared document length does not match the input size");
    }
    let frames: [DecodeFrame] = [];
    push(frames, bson_new_decode_frame(0, root_len, 1, "", 0));
    let values = 0;

    while len(frames) > 0 {
        let frame = frames[len(frames) - 1];
        let terminal = frame.end - 1;
        if frame.pos == terminal {
            if raw[terminal] != 0 {
                return err("bson.decode: missing document terminator");
            }
            let child_document = frame.document;
            let child_value = bson_decode_frame_value(frame);
            let child = pop(frames);
            if len(frames) == 0 {
                if child.array {
                    return err("bson.decode: top-level BSON value must be a document");
                }
                if child.end != len(raw) {
                    return err("bson.decode: trailing bytes after the document");
                }
                return ok(child_document);
            }

            let parent = frames[len(frames) - 1];
            parent.pos = child.end;
            if parent.array {
                let expected = to_str(parent.next_array_index);
                if child.parent_key != expected {
                    return err("bson.decode: array index is not the expected " + expected);
                }
                push(parent.array_values, child_value);
                parent.next_array_index = parent.next_array_index + 1;
            } else {
                // The key was UTF-8 and duplicate-checked before its child
                // frame was pushed. Appending here avoids scanning all
                // preceding fields a second time through put().
                bson_decode_append(parent.document, child.parent_key,
                                   child_value);
            }
            continue;
        }
        if frame.pos > terminal {
            return err("bson.decode: element passes the document boundary");
        }

        values = values + 1;
        if values > limits.max_values {
            return err("bson.decode: value count exceeds configured limit");
        }
        let kind = raw[frame.pos];
        if kind == 0 {
            return err("bson.decode: early document terminator");
        }
        let key_start = frame.pos + 1;
        let kr = bson_read_cstring(raw, key_start, terminal);
        guard let key_result = kr else let e = err_of(kr) {
            return err("bson.decode: " + e);
        }
        let key_bytes = key_result.raw;
        if !bson_valid_utf8(key_bytes, 0, len(key_bytes)) {
            return err("bson.decode: field name is not valid UTF-8");
        }
        let key = to_str(key_bytes);
        if !frame.array && bson_find_field(frame.document, key) >= 0 {
            return err("bson.decode: duplicate field name " + key);
        }
        if frame.array {
            let expected = to_str(frame.next_array_index);
            if key != expected {
                return err("bson.decode: array index is not the expected " + expected);
            }
        }

        if kind == BSON_DOCUMENT || kind == BSON_ARRAY {
            let start = key_result.next;
            if !bson_has_range(raw, start, 4, terminal) {
                return err("bson.decode: truncated nested document length");
            }
            let nested_len = bson_read_i32(raw, start);
            if nested_len < 5 || nested_len > limits.max_document_bytes {
                return err("bson.decode: invalid nested document length");
            }
            if nested_len > terminal - start {
                return err("bson.decode: nested document exceeds its parent boundary");
            }
            if frame.depth >= limits.max_depth {
                return err("bson.decode: nesting depth exceeds configured limit");
            }
            push(frames, bson_new_decode_frame(start, nested_len,
                                               frame.depth + 1, key, kind));
            continue;
        }

        let vr = bson_decode_scalar(raw, key_result.next, terminal, kind);
        guard let decoded = vr else let e = err_of(vr) {
            return err(e);
        }
        frame.pos = decoded.next;
        if frame.array {
            push(frame.array_values, decoded.value);
            frame.next_array_index = frame.next_array_index + 1;
        } else {
            // The key was UTF-8 and duplicate-checked above.
            bson_decode_append(frame.document, key, decoded.value);
        }
    }

    return err("bson.decode: internal traversal ended without a document");
}

fn bson_decode_append(doc: Document, key: str, value: Value) {
    push(doc.fields, Field { key: key, value: value });
}

fn bson_new_decode_frame(start: int, size: int, depth: int,
                         parent_key: str, parent_type: int) -> DecodeFrame {
    let doc = document();
    let values: [Value] = [];
    return DecodeFrame {
        document: doc,
        array_values: values,
        array: parent_type == BSON_ARRAY,
        pos: start + 4,
        end: start + size,
        depth: depth,
        next_array_index: 0,
        parent_key: parent_key,
        parent_type: parent_type
    };
}

fn bson_decode_frame_value(frame: DecodeFrame) -> Value {
    if frame.array {
        return array_value(frame.array_values);
    }
    return document_value(frame.document);
}

fn bson_has_range(raw: bytes, pos: int, count: int, end: int) -> bool {
    return pos >= 0 && count >= 0 && end >= 0 && end <= len(raw) &&
           pos <= end && count <= end - pos;
}

fn bson_read_i32(raw: bytes, pos: int) -> int {
    let value = raw[pos] + raw[pos + 1] * 256 +
                raw[pos + 2] * 65536 + raw[pos + 3] * 16777216;
    if raw[pos + 3] >= 128 {
        return value - 4294967296;
    }
    return value;
}

fn bson_read_i64(raw: bytes, pos: int) -> int {
    return from_le(raw[pos..pos + 8]);
}

fn bson_read_u64(raw: bytes, pos: int) -> u64 {
    let value: u64 = 0;
    let place: u64 = 1;
    let i = 0;
    while i < 8 {
        value = value + (raw[pos + i] as u64) * place;
        if i < 7 {
            place = place * 256;
        }
        i = i + 1;
    }
    return value;
}

fn bson_read_cstring(raw: bytes, pos: int, end: int)
                     -> result[BsonCString, str] {
    if pos < 0 || end < pos || end > len(raw) {
        return err("invalid cstring boundary");
    }
    let i = pos;
    while i < end && raw[i] != 0 {
        i = i + 1;
    }
    if i >= end {
        return err("unterminated cstring");
    }
    let value = raw[pos..i];
    if !bson_valid_utf8(value, 0, len(value)) {
        return err("cstring is not valid UTF-8");
    }
    return ok(BsonCString { raw: value, next: i + 1 });
}

fn bson_decode_scalar(raw: bytes, pos: int, end: int, kind: int)
                     -> result[DecodedBsonValue, str] {
    let value = null_value();
    let next = pos;
    if kind == BSON_DOUBLE {
        if !bson_has_range(raw, pos, 8, end) {
            return err("bson.decode: truncated double");
        }
        let converted = encoding.float64_from_le(raw[pos..pos + 8]);
        guard let number = converted else let e = err_of(converted) {
            return err("bson.decode: invalid double: " + e);
        }
        value = double_value(number);
        next = pos + 8;
    } else if kind == BSON_STRING {
        if !bson_has_range(raw, pos, 4, end) {
            return err("bson.decode: truncated string length");
        }
        let n = bson_read_i32(raw, pos);
        if n < 1 || !bson_has_range(raw, pos + 4, n, end) {
            return err("bson.decode: invalid or truncated string");
        }
        let start = pos + 4;
        let terminator = start + n - 1;
        if raw[terminator] != 0 {
            return err("bson.decode: BSON string has no trailing NUL");
        }
        let data = raw[start..terminator];
        if !bson_valid_utf8(data, 0, len(data)) {
            return err("bson.decode: string value is not valid UTF-8");
        }
        let made = string_bytes_value(data);
        guard let string = made else let e = err_of(made) {
            return err("bson.decode: " + e);
        }
        value = string;
        next = terminator + 1;
    } else if kind == BSON_BINARY {
        if !bson_has_range(raw, pos, 5, end) {
            return err("bson.decode: truncated binary header");
        }
        let n = bson_read_i32(raw, pos);
        if n < 0 || !bson_has_range(raw, pos + 5, n, end) {
            return err("bson.decode: invalid or truncated binary payload");
        }
        let subtype = raw[pos + 4];
        let data_start = pos + 5;
        let data_len = n;
        if subtype == 2 {
            if n < 4 {
                return err("bson.decode: legacy binary payload is shorter than its nested length");
            }
            let nested_len = bson_read_i32(raw, pos + 5);
            if nested_len < 0 || nested_len != n - 4 {
                return err("bson.decode: legacy binary nested length does not match its payload");
            }
            data_start = pos + 9;
            data_len = nested_len;
        }
        let made = binary_value(raw[data_start..data_start + data_len], subtype);
        guard let binary = made else let e = err_of(made) {
            return err("bson.decode: " + e);
        }
        value = binary;
        next = pos + 5 + n;
    } else if kind == BSON_OBJECT_ID {
        if !bson_has_range(raw, pos, 12, end) {
            return err("bson.decode: truncated ObjectId");
        }
        let made = object_id_value(raw[pos..pos + 12]);
        guard let object_id = made else let e = err_of(made) {
            return err("bson.decode: " + e);
        }
        value = object_id;
        next = pos + 12;
    } else if kind == BSON_BOOL {
        if !bson_has_range(raw, pos, 1, end) {
            return err("bson.decode: truncated boolean");
        }
        if raw[pos] > 1 {
            return err("bson.decode: boolean byte must be 0 or 1");
        }
        value = bool_value(raw[pos] == 1);
        next = pos + 1;
    } else if kind == BSON_DATETIME || kind == BSON_INT64 {
        if !bson_has_range(raw, pos, 8, end) {
            return err("bson.decode: truncated 64-bit value");
        }
        let number = bson_read_i64(raw, pos);
        if kind == BSON_DATETIME {
            value = datetime_value(number);
        } else {
            value = int64_value(number);
        }
        next = pos + 8;
    } else if kind == BSON_TIMESTAMP {
        if !bson_has_range(raw, pos, 8, end) {
            return err("bson.decode: truncated timestamp");
        }
        value = timestamp_value(bson_read_u64(raw, pos));
        next = pos + 8;
    } else if kind == BSON_INT32 {
        if !bson_has_range(raw, pos, 4, end) {
            return err("bson.decode: truncated int32");
        }
        let made = int32_value(bson_read_i32(raw, pos));
        guard let number = made else let e = err_of(made) {
            return err("bson.decode: " + e);
        }
        value = number;
        next = pos + 4;
    } else if kind == BSON_DECIMAL128 {
        if !bson_has_range(raw, pos, 16, end) {
            return err("bson.decode: truncated Decimal128");
        }
        let made = decimal128_value(raw[pos..pos + 16]);
        guard let decimal = made else let e = err_of(made) {
            return err("bson.decode: " + e);
        }
        value = decimal;
        next = pos + 16;
    } else if kind == BSON_REGEX {
        let pattern_result = bson_read_cstring(raw, pos, end);
        guard let pattern = pattern_result else let e = err_of(pattern_result) {
            return err("bson.decode: invalid regex pattern: " + e);
        }
        let options_result = bson_read_cstring(raw, pattern.next, end);
        guard let options = options_result else let e = err_of(options_result) {
            return err("bson.decode: invalid regex options: " + e);
        }
        let made = regex_value(to_str(pattern.raw), to_str(options.raw));
        guard let regex = made else let e = err_of(made) {
            return err("bson.decode: " + e);
        }
        value = regex;
        next = options.next;
    } else if kind == 10 || kind == 255 || kind == 127 {
        if kind == 10 {
            value = null_value();
        } else if kind == 255 {
            value = min_key_value();
        } else {
            value = max_key_value();
        }
    } else {
        return err("bson.decode: unsupported BSON type tag " + to_str(kind));
    }
    return ok(DecodedBsonValue { value: value, next: next });
}
