import "strings";
import "encoding";

pub let DEFAULT_PORT = 27017;
pub let DEFAULT_MAX_MESSAGE_BYTES = 50331648;

pub gc struct Config {
    host: str,
    port: int,
    database: str,
    auth_source: str,
    username: str,
    password: str,
    auth_mechanism: str,
    tls: bool,
    ca_file: str,
    app_name: str,
    max_bson_bytes: int,
    max_message_bytes: int,
    tls_context: rawptr,
}

pub fn new_config(host: str, port: int, database: str)
                 -> result[Config, str] {
    if !mongo_host_valid(host) {
        return err("mongo.new_config: host is empty or contains URI delimiters");
    }
    if port < 1 || port > 65535 {
        return err("mongo.new_config: port must be between 1 and 65535");
    }
    if len(database) == 0 {
        return err("mongo.new_config: database cannot be empty");
    }
    return ok(Config {
        host: host,
        port: port,
        database: database,
        auth_source: "admin",
        username: "",
        password: "",
        auth_mechanism: "SCRAM-SHA-256",
        tls: false,
        ca_file: "",
        app_name: "",
        max_bson_bytes: DEFAULT_MAX_BSON_BYTES,
        max_message_bytes: DEFAULT_MAX_MESSAGE_BYTES,
        tls_context: nullptr
    });
}

// Only one mongodb:// endpoint is supported initially. Credentials and
// database/query components use strict percent decoding; unknown options and
// duplicate keys fail closed so security-sensitive settings cannot conflict.
pub fn parse_uri(uri: str) -> result[Config, str] {
    if len(uri) > 8192 {
        return err("mongo.parse_uri: URI exceeds 8192 bytes");
    }
    if !strings.has_prefix(uri, "mongodb://") {
        return err("mongo.parse_uri: expected mongodb://; SRV URIs are unsupported");
    }
    let rest = strings.slice(uri, 10, len(uri));
    let query = "";
    let query_at = strings.find(rest, "?");
    if query_at >= 0 {
        query = strings.slice(rest, query_at + 1, len(rest));
        rest = strings.slice(rest, 0, query_at);
    }
    if strings.contains(rest, "#") {
        return err("mongo.parse_uri: URI fragments are not supported; percent-encode reserved bytes");
    }

    let authority = rest;
    let database = "test";
    let has_database = false;
    let slash = strings.find(rest, "/");
    if slash >= 0 {
        authority = strings.slice(rest, 0, slash);
        let path = strings.slice(rest, slash + 1, len(rest));
        if strings.contains(path, "/") {
            return err("mongo.parse_uri: database path must be one component");
        }
        if path != "" {
            let decoded = encoding.url_decode(path);
            guard let name = decoded else {
                return err("mongo.parse_uri: invalid percent escape in database name");
            }
            if name == "" {
                return err("mongo.parse_uri: database name cannot be empty");
            }
            database = name;
            has_database = true;
        }
    }

    let username = "";
    let password = "";
    let at = strings.rfind(authority, "@");
    if at >= 0 {
        if strings.find(strings.slice(authority, 0, at), "@") >= 0 {
            return err("mongo.parse_uri: encode @ in credentials as %40");
        }
        let userinfo = strings.slice(authority, 0, at);
        authority = strings.slice(authority, at + 1, len(authority));
        let colon = strings.find(userinfo, ":");
        let raw_user = userinfo;
        if colon >= 0 {
            raw_user = strings.slice(userinfo, 0, colon);
            let decoded_password = encoding.url_decode(
                strings.slice(userinfo, colon + 1, len(userinfo)));
            guard let p = decoded_password else {
                return err("mongo.parse_uri: invalid percent escape in password");
            }
            password = p;
        }
        let decoded_user = encoding.url_decode(raw_user);
        guard let u = decoded_user else {
            return err("mongo.parse_uri: invalid percent escape in username");
        }
        if u == "" {
            return err("mongo.parse_uri: username cannot be empty when credentials are present");
        }
        username = u;
    }

    let host = authority;
    let port = DEFAULT_PORT;
    if strings.has_prefix(authority, "[") {
        let close = strings.find(authority, "]");
        if close <= 1 {
            return err("mongo.parse_uri: invalid IPv6 literal");
        }
        host = strings.slice(authority, 1, close);
        let suffix = strings.slice(authority, close + 1, len(authority));
        if suffix != "" {
            if !strings.has_prefix(suffix, ":") {
                return err("mongo.parse_uri: invalid text after IPv6 literal");
            }
            let parsed_port = mongo_parse_decimal(
                strings.slice(suffix, 1, len(suffix)), 65535);
            guard let p = parsed_port else {
                return err("mongo.parse_uri: port must be a decimal integer from 1 to 65535");
            }
            port = p;
        }
    } else {
        let colon = strings.rfind(authority, ":");
        if colon >= 0 {
            if strings.find(authority, ":") != colon {
                return err("mongo.parse_uri: IPv6 literals must be enclosed in brackets");
            }
            let parsed_port = mongo_parse_decimal(
                strings.slice(authority, colon + 1, len(authority)), 65535);
            guard let p = parsed_port else {
                return err("mongo.parse_uri: port must be a decimal integer from 1 to 65535");
            }
            port = p;
            host = strings.slice(authority, 0, colon);
        }
    }
    if !mongo_host_valid(host) {
        return err("mongo.parse_uri: host is empty or contains URI delimiters");
    }
    if strings.contains(host, ",") {
        return err("mongo.parse_uri: multiple hosts are unsupported");
    }

    let configured = new_config(host, port, database);
    guard let cfg = configured else let e = err_of(configured) {
        return err(e);
    }
    cfg.username = username;
    cfg.password = password;
    if username != "" && has_database {
        cfg.auth_source = database;
    }

    let seen: [str] = [];
    let tls_explicit = false;
    let tls_explicit_value = false;
    if query != "" {
        for part in strings.split(query, "&") {
            if part == "" {
                return err("mongo.parse_uri: query contains an empty option");
            }
            let equals = strings.find(part, "=");
            if equals <= 0 {
                return err("mongo.parse_uri: each query option must have a name and value");
            }
            let key_result = encoding.url_decode(strings.slice(part, 0, equals));
            guard let key_raw = key_result else {
                return err("mongo.parse_uri: invalid percent escape in option name");
            }
            let key = strings.to_lower(key_raw);
            if key == "" || mongo_contains_string(seen, key) {
                return err("mongo.parse_uri: empty or duplicate option name");
            }
            push(seen, key);
            let value_result = encoding.url_decode(
                strings.slice(part, equals + 1, len(part)));
            guard let value = value_result else {
                return err("mongo.parse_uri: invalid percent escape in option value");
            }
            if key == "tls" {
                tls_explicit = true;
                if value == "true" {
                    tls_explicit_value = true;
                } else if value == "false" {
                    tls_explicit_value = false;
                } else {
                    return err("mongo.parse_uri: tls must be true or false");
                }
            } else if key == "tlscafile" {
                if value == "" {
                    return err("mongo.parse_uri: tlsCAFile cannot be empty");
                }
                cfg.ca_file = value;
            } else if key == "authsource" {
                if value == "" {
                    return err("mongo.parse_uri: authSource cannot be empty");
                }
                cfg.auth_source = value;
            } else if key == "authmechanism" {
                if value != "SCRAM-SHA-256" {
                    return err("mongo.parse_uri: only SCRAM-SHA-256 is supported");
                }
                cfg.auth_mechanism = value;
            } else if key == "appname" {
                if len(value) > 128 {
                    return err("mongo.parse_uri: appName exceeds 128 bytes");
                }
                cfg.app_name = value;
            } else if key == "directconnection" {
                if value != "true" {
                    return err("mongo.parse_uri: only directConnection=true is supported");
                }
            } else {
                return err("mongo.parse_uri: unsupported option " + key_raw);
            }
        }
    }
    if cfg.ca_file != "" && tls_explicit && !tls_explicit_value {
        return err("mongo.parse_uri: tlsCAFile conflicts with tls=false");
    }
    if cfg.ca_file != "" || tls_explicit_value {
        cfg.tls = true;
    } else if tls_explicit {
        cfg.tls = false;
    }
    return ok(cfg);
}

fn mongo_host_valid(host: str) -> bool {
    if host == "" {
        return false;
    }
    let raw = to_bytes(host);
    let i = 0;
    while i < len(raw) {
        let b = raw[i];
        if b <= 32 || b == 127 || b == 47 || b == 63 || b == 35 ||
           b == 64 || b == 44 || b == 91 || b == 93 {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn mongo_parse_decimal(raw: str, max_value: int) -> opt[int] {
    if raw == "" {
        return none;
    }
    let encoded = to_bytes(raw);
    let value = 0;
    let i = 0;
    while i < len(encoded) {
        let b = encoded[i];
        if b < 48 || b > 57 {
            return none;
        }
        let digit = b - 48;
        if value > (max_value - digit) / 10 {
            return none;
        }
        value = value * 10 + digit;
        i = i + 1;
    }
    if value < 1 {
        return none;
    }
    return some(value);
}

fn mongo_contains_string(values: [str], wanted: str) -> bool {
    let i = 0;
    while i < len(values) {
        if values[i] == wanted {
            return true;
        }
        i = i + 1;
    }
    return false;
}
