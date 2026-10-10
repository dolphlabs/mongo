pub fn encode(doc: Document) -> result[bytes, str] {
    return encode_with_limits(doc, default_limits());
}

pub fn encode_with_limits(doc: Document, limits: Limits)
                          -> result[bytes, str] {
    if !bson_limits_valid(limits) {
        return err("bson.encode: invalid limits");
    }
    let root = document_value(doc);
    let frames: [EncodeFrame] = [];
    push(frames, bson_new_encode_frame(root, 1, "", 0));
    let values = 0;

    while len(frames) > 0 {
        let frame = frames[len(frames) - 1];
        let count = bson_encode_frame_count(frame.source);
        if count < 0 {
            return err("bson.encode: document or array payload is missing");
        }

        if frame.index < count {
            let key = bson_encode_frame_key(frame, frame.index);
            let value = bson_encode_frame_value(frame, frame.index);
            frame.index = frame.index + 1;
            values = values + 1;
            if values > limits.max_values {
                return err("bson.encode: value count exceeds configured limit");
            }

            if value.kind == BSON_DOCUMENT || value.kind == BSON_ARRAY {
                if frame.depth >= limits.max_depth {
                    return err("bson.encode: nesting depth exceeds configured limit");
                }
                push(frames, bson_new_encode_frame(value, frame.depth + 1,
                                                   key, value.kind));
            } else {
                let wr = bson_encode_scalar(frame, key, value, limits);
                guard let _ok = wr else let e = err_of(wr) {
                    return err(e);
                }
            }
            continue;
        }

        if frame.out.size() + 1 > limits.max_document_bytes {
            return err("bson.encode: document exceeds configured byte limit");
        }
        frame.out.write_byte(0);
        let raw = frame.out.finish();
        if len(raw) > limits.max_document_bytes || len(raw) > 2147483647 {
            return err("bson.encode: document exceeds configured byte limit");
        }
        bson_patch_length(raw);
        let child = pop(frames);
        if len(frames) == 0 {
            return ok(raw);
        }

        let parent = frames[len(frames) - 1];
        if !bson_encode_fits(parent, child.parent_key, len(raw), limits) {
            return err("bson.encode: document exceeds configured byte limit");
        }
        bson_encode_write_head(parent.out, child.parent_type, child.parent_key);
        parent.out.write(raw);
    }

    return err("bson.encode: internal traversal ended without a document");
}

fn bson_new_encode_frame(source: Value, depth: int, parent_key: str,
                         parent_type: int) -> EncodeFrame {
    let out = builder.new_bytes();
    out.write(to_le(0)[0..4]);
    return EncodeFrame {
        source: source,
        index: 0,
        depth: depth,
        parent_key: parent_key,
        parent_type: parent_type,
        out: out
    };
}

fn bson_encode_frame_count(source: Value) -> int {
    if source.kind == BSON_DOCUMENT {
        guard let doc = source.document else {
            return -1;
        }
        return len(doc.fields);
    }
    if source.kind == BSON_ARRAY {
        return len(source.items);
    }
    return -1;
}

fn bson_encode_frame_key(frame: EncodeFrame, index: int) -> str {
    if frame.source.kind == BSON_ARRAY {
        return to_str(index);
    }
    guard let doc = frame.source.document else {
        return "";
    }
    return doc.fields[index].key;
}

fn bson_encode_frame_value(frame: EncodeFrame, index: int) -> Value {
    if frame.source.kind == BSON_ARRAY {
        return frame.source.items[index];
    }
    guard let doc = frame.source.document else {
        return null_value();
    }
    return doc.fields[index].value;
}

fn bson_encode_fits(frame: EncodeFrame, key: str, payload_bytes: int,
                    limits: Limits) -> bool {
    let raw_key = to_bytes(key);
    if bson_has_zero(raw_key) ||
       !bson_valid_utf8(raw_key, 0, len(raw_key)) {
        return false;
    }
    if payload_bytes < 0 || frame.out.size() > limits.max_document_bytes {
        return false;
    }
    let added = 1 + len(raw_key) + 1 + payload_bytes + 1;
    return added <= limits.max_document_bytes - frame.out.size();
}

fn bson_encode_write_head(out: builder.Bytes, kind: int, key: str) {
    out.write_byte(kind);
    out.write_str(key);
    out.write_byte(0);
}

fn bson_encode_scalar(frame: EncodeFrame, key: str, value: Value,
                      limits: Limits) -> result[bool, str] {
    let payload = 0;
    if value.kind == BSON_DOUBLE {
        payload = 8;
    } else if value.kind == BSON_STRING {
        if !bson_valid_utf8(value.data, 0, len(value.data)) {
            return err("bson.encode: string value is not valid UTF-8");
        }
        if len(value.data) >= 2147483647 {
            return err("bson.encode: string value is too large");
        }
        payload = 4 + len(value.data) + 1;
    } else if value.kind == BSON_BINARY {
        if value.subtype < 0 || value.subtype > 255 ||
           len(value.data) > 2147483647 ||
           (value.subtype == 2 && len(value.data) > 2147483643) {
            return err("bson.encode: invalid binary payload");
        }
        payload = 5 + len(value.data);
        if value.subtype == 2 {
            payload = payload + 4;
        }
    } else if value.kind == BSON_OBJECT_ID {
        if len(value.data) != 12 {
            return err("bson.encode: ObjectId must be exactly 12 bytes");
        }
        payload = 12;
    } else if value.kind == BSON_BOOL {
        payload = 1;
    } else if value.kind == BSON_DATETIME || value.kind == BSON_TIMESTAMP ||
              value.kind == BSON_INT64 {
        payload = 8;
    } else if value.kind == BSON_INT32 {
        if value.int_value < -2147483648 || value.int_value > 2147483647 {
            return err("bson.encode: int32 value is outside its range");
        }
        payload = 4;
    } else if value.kind == BSON_DECIMAL128 {
        if len(value.data) != 16 {
            return err("bson.encode: Decimal128 must be exactly 16 bytes");
        }
        payload = 16;
    } else if value.kind == BSON_NULL || value.kind == BSON_MIN_KEY ||
              value.kind == BSON_MAX_KEY {
        payload = 0;
    } else if value.kind == BSON_REGEX {
        let pattern = to_bytes(value.text);
        let options = to_bytes(value.aux);
        if bson_has_zero(pattern) || bson_has_zero(options) ||
           !bson_valid_utf8(pattern, 0, len(pattern)) ||
           !bson_valid_utf8(options, 0, len(options)) {
            return err("bson.encode: regex pattern/options must be valid cstrings");
        }
        payload = len(pattern) + len(options) + 2;
    } else {
        return err("bson.encode: unsupported BSON type tag " + to_str(value.kind));
    }

    if !bson_encode_fits(frame, key, payload, limits) {
        return err("bson.encode: document exceeds configured byte limit or has an invalid field name");
    }
    bson_encode_write_head(frame.out, value.kind, key);

    if value.kind == BSON_DOUBLE {
        frame.out.write(encoding.float64_to_le(value.float_value));
    } else if value.kind == BSON_STRING {
        bson_write_i32(frame.out, len(value.data) + 1);
        frame.out.write(value.data);
        frame.out.write_byte(0);
    } else if value.kind == BSON_BINARY {
        let wire_len = len(value.data);
        if value.subtype == 2 {
            wire_len = wire_len + 4;
        }
        bson_write_i32(frame.out, wire_len);
        frame.out.write_byte(value.subtype);
        if value.subtype == 2 {
            bson_write_i32(frame.out, len(value.data));
        }
        frame.out.write(value.data);
    } else if value.kind == BSON_OBJECT_ID || value.kind == BSON_DECIMAL128 {
        frame.out.write(value.data);
    } else if value.kind == BSON_BOOL {
        let bool_byte = 0;
        if value.bool_value {
            bool_byte = 1;
        }
        frame.out.write_byte(bool_byte);
    } else if value.kind == BSON_DATETIME || value.kind == BSON_INT64 {
        frame.out.write(to_le(value.int_value));
    } else if value.kind == BSON_TIMESTAMP {
        frame.out.write(to_le(value.uint_value));
    } else if value.kind == BSON_INT32 {
        bson_write_i32(frame.out, value.int_value);
    } else if value.kind == BSON_REGEX {
        frame.out.write_str(value.text);
        frame.out.write_byte(0);
        frame.out.write_str(value.aux);
        frame.out.write_byte(0);
    }
    return ok(true);
}

fn bson_write_i32(out: builder.Bytes, value: int) {
    out.write(to_le(value)[0..4]);
}

fn bson_patch_length(raw: bytes) {
    let encoded = to_le(len(raw));
    let i = 0;
    while i < 4 {
        raw[i] = encoded[i];
        i = i + 1;
    }
}
