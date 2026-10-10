import "crypto";
import "encoding";
import "builder";
import "strings";

let MONGO_SCRAM_MIN_ITERATIONS = 4096;
let MONGO_SCRAM_MAX_ITERATIONS = 1000000;
let MONGO_SCRAM_MAX_TEXT_BYTES = 4096;
let MONGO_SCRAM_MAX_SALT_BYTES = 1024;

struct ScramClientProof {
    payload: bytes,
    server_signature: bytes,
}

// Compute one SCRAM-SHA-256 proof from the server-first message. Username and
// password are limited to printable ASCII until slang has a SASLprep Unicode
// normalizer; rejecting unsupported input is safer than hashing it differently
// from MongoDB.
fn mongo_scram_client_proof(username: str, password: str,
                            client_nonce: str, server_first: str)
                            -> result[ScramClientProof, str] {
    if !mongo_scram_ascii(username) || !mongo_scram_ascii(password) {
        return err("mongo SCRAM-SHA-256 currently requires printable ASCII credentials");
    }
    if len(server_first) == 0 || len(server_first) > MONGO_SCRAM_MAX_TEXT_BYTES {
        return err("mongo SCRAM: server-first message has an invalid size");
    }
    if client_nonce == "" || strings.contains(client_nonce, ",") {
        return err("mongo SCRAM: client nonce is invalid");
    }
    let nonce = "";
    let salt_text = "";
    let iterations_text = "";
    let seen: [str] = [];
    for attribute in strings.split(server_first, ",") {
        let separator = strings.find(attribute, "=");
        if separator != 1 || len(attribute) <= 2 {
            return err("mongo SCRAM: malformed server attribute");
        }
        let name = strings.slice(attribute, 0, 1);
        if mongo_contains_string(seen, name) {
            return err("mongo SCRAM: duplicate server attribute");
        }
        push(seen, name);
        let value = strings.slice(attribute, 2, len(attribute));
        if name == "r" {
            nonce = value;
        } else if name == "s" {
            salt_text = value;
        } else if name == "i" {
            iterations_text = value;
        } else if name == "m" {
            return err("mongo SCRAM: server requires an unsupported extension");
        }
    }
    if !strings.has_prefix(nonce, client_nonce) || len(nonce) <= len(client_nonce) {
        return err("mongo SCRAM: server nonce does not extend the client nonce");
    }
    let salt_result = encoding.base64_decode(salt_text);
    guard let salt = salt_result else {
        return err("mongo SCRAM: server salt is not valid base64");
    }
    if len(salt) == 0 || len(salt) > MONGO_SCRAM_MAX_SALT_BYTES {
        return err("mongo SCRAM: server salt is outside the supported size");
    }
    let parsed_iterations = mongo_parse_decimal(iterations_text,
                                                MONGO_SCRAM_MAX_ITERATIONS);
    guard let iterations = parsed_iterations else {
        return err("mongo SCRAM: invalid iteration count");
    }
    if iterations < MONGO_SCRAM_MIN_ITERATIONS {
        return err("mongo SCRAM: server iteration count is below 4096");
    }

    let derived = crypto.pbkdf2_sha256(to_bytes(password), salt,
                                       iterations, 32);
    guard let salted_password = derived else let e = err_of(derived) {
        return err("mongo SCRAM: key derivation failed: " + e);
    }
    let client_key = crypto.hmac_sha256(salted_password, b"Client Key");
    let stored_key = crypto.sha256(client_key);
    let client_without_proof = "c=biws,r=" + nonce;
    let client_first_bare = "n=" + mongo_scram_escape_username(username) +
                            ",r=" + client_nonce;
    let auth_message = client_first_bare + "," + server_first + "," +
                       client_without_proof;
    let client_signature = crypto.hmac_sha256(stored_key,
                                               to_bytes(auth_message));
    let proof = mongo_scram_xor(client_key, client_signature);
    let server_key = crypto.hmac_sha256(salted_password, b"Server Key");
    let server_signature = crypto.hmac_sha256(server_key,
                                                to_bytes(auth_message));
    let final_text = client_without_proof + ",p=" +
                     encoding.base64_encode(proof);
    return ok(ScramClientProof {
        payload: to_bytes(final_text),
        server_signature: server_signature
    });
}

fn mongo_scram_ascii(value: str) -> bool {
    if len(value) > MONGO_SCRAM_MAX_TEXT_BYTES {
        return false;
    }
    let raw = to_bytes(value);
    let i = 0;
    while i < len(raw) {
        if raw[i] < 32 || raw[i] > 126 {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn mongo_scram_message_from_bytes(raw: bytes) -> result[str, str] {
    if len(raw) == 0 || len(raw) > MONGO_SCRAM_MAX_TEXT_BYTES {
        return err("mongo SCRAM: server message has an invalid size");
    }
    let i = 0;
    while i < len(raw) {
        if raw[i] < 32 || raw[i] > 126 {
            return err("mongo SCRAM: server message is not printable ASCII");
        }
        i = i + 1;
    }
    return ok(to_str(raw));
}

fn mongo_scram_escape_username(username: str) -> str {
    let raw = to_bytes(username);
    let out = builder.new_bytes();
    let i = 0;
    while i < len(raw) {
        if raw[i] == 61 {
            out.write(b"=3D");
        } else if raw[i] == 44 {
            out.write(b"=2C");
        } else {
            out.write_byte(raw[i]);
        }
        i = i + 1;
    }
    return to_str(out.finish());
}

fn mongo_scram_xor(a: bytes, b: bytes) -> bytes {
    if len(a) != len(b) {
        return b"";
    }
    let out = builder.new_bytes();
    let i = 0;
    while i < len(a) {
        out.write_byte(a[i] ^ b[i]);
        i = i + 1;
    }
    return out.finish();
}

fn mongo_scram_equal_constant_time(a: bytes, b: bytes) -> bool {
    if len(a) != len(b) {
        return false;
    }
    let difference = 0;
    let i = 0;
    while i < len(a) {
        difference = difference | (a[i] ^ b[i]);
        i = i + 1;
    }
    return difference == 0;
}
