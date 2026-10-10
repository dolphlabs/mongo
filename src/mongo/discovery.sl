import "net";
import "strings";
import "encoding";

pub gc struct MongoSeed {
    host: str,
    port: int,
}

pub gc struct MongoDiscovery {
    config: Config,
    seeds: [MongoSeed],
}

fn mongo_srv_discover(cfg: Config, deadline: until)
                       -> result[MongoDiscovery, str] {
    let txt_result = net.lookup_txt_until(cfg.host, deadline);
    guard let txt_records = txt_result else let e = err_of(txt_result) {
        return err("mongo.connect: TXT lookup failed: " + e);
    }
    if len(txt_records) > 1 {
        return err("mongo.connect: SRV URI returned multiple TXT records");
    }
    if len(txt_records) == 1 {
        let applied = mongo_apply_srv_txt(cfg, txt_records[0]);
        guard let _ok = applied else let e = err_of(applied) { return err(e); }
    }
    if cfg.load_balanced {
        return err("mongo.connect: loadBalanced=true is not supported");
    }

    let service = "_" + cfg.srv_service_name + "._tcp." + cfg.host;
    let srv_result = net.lookup_srv_until(service, deadline);
    guard let srv_records = srv_result else let e = err_of(srv_result) {
        return err("mongo.connect: SRV lookup failed: " + e);
    }
    if len(srv_records) == 0 || len(srv_records) > 256 {
        return err("mongo.connect: SRV lookup returned no usable seeds");
    }
    let seeds: [MongoSeed] = [];
    for record in srv_records {
        let parsed = mongo_parse_srv_seed(cfg.host, record);
        guard let seed = parsed else let e = err_of(parsed) { return err(e); }
        push(seeds, seed);
    }
    return ok(MongoDiscovery { config: cfg, seeds: seeds });
}

fn mongo_connect_seeds(cfg: Config, seeds: [MongoSeed], deadline: until)
                        -> result[Conn, str] {
    if len(seeds) == 0 {
        return err("mongo.connect: SRV lookup returned no usable seeds");
    }
    let ready = cfg;
    if ready.tls && ready.tls_context == nullptr {
        let context = net.tls_client_ctx(ready.ca_file);
        guard let tls_context = context else let e = err_of(context) {
            return err("mongo.connect: TLS context failed: " + e);
        }
        ready.tls_context = tls_context;
    }
    let last_error = "no seed accepted a connection";
    for seed in seeds {
        if until_hit(deadline) {
            return err("mongo.connect: deadline expired while selecting a writable primary");
        }
        let attempt = mongo_connect_host(ready, seed.host, seed.port,
                                         deadline, true);
        if let connection = attempt {
            return ok(connection);
        } else let e = err_of(attempt) {
            last_error = e;
        }
    }
    return err("mongo.connect: no writable primary among " + to_str(len(seeds)) +
               " SRV seeds: " + last_error);
}

fn mongo_apply_srv_txt(cfg: Config, raw: str) -> result[bool, str] {
    if raw == "" || len(raw) > 8192 {
        return err("mongo.connect: TXT options are empty or exceed the size limit");
    }
    let seen: [str] = [];
    for part in strings.split(raw, "&") {
        let equals = strings.find(part, "=");
        if part == "" || equals <= 0 {
            return err("mongo.connect: malformed TXT connection option");
        }
        let key_result = encoding.url_decode(strings.slice(part, 0, equals));
        guard let key_raw = key_result else {
            return err("mongo.connect: malformed TXT option name escape");
        }
        let key = strings.to_lower(key_raw);
        if key == "" || mongo_contains_string(seen, key) {
            return err("mongo.connect: duplicate or empty TXT option name");
        }
        push(seen, key);
        let value_result = encoding.url_decode(
            strings.slice(part, equals + 1, len(part)));
        guard let value = value_result else {
            return err("mongo.connect: malformed TXT option value escape");
        }
        if key == "authsource" {
            if value == "" {
                return err("mongo.connect: TXT authSource cannot be empty");
            }
            if !cfg.auth_source_explicit { cfg.auth_source = value; }
        } else if key == "replicaset" {
            if value == "" {
                return err("mongo.connect: TXT replicaSet cannot be empty");
            }
            if !cfg.replica_set_explicit { cfg.replica_set = value; }
        } else if key == "loadbalanced" {
            let enabled = false;
            if value == "true" {
                enabled = true;
            } else if value != "false" {
                return err("mongo.connect: TXT loadBalanced must be true or false");
            }
            if !cfg.load_balanced_explicit { cfg.load_balanced = enabled; }
        } else {
            return err("mongo.connect: unsupported TXT option " + key_raw);
        }
    }
    return ok(true);
}

fn mongo_parse_srv_seed(uri_host: str, raw: str) -> result[MongoSeed, str] {
    let fields = strings.split(raw, ":");
    if len(fields) != 4 {
        return err("mongo.connect: malformed SRV record");
    }
    let priority = mongo_parse_unsigned(fields[0], 65535);
    guard let _priority = priority else {
        return err("mongo.connect: malformed SRV priority");
    }
    let weight = mongo_parse_unsigned(fields[1], 65535);
    guard let _weight = weight else {
        return err("mongo.connect: malformed SRV weight");
    }
    let port_result = mongo_parse_unsigned(fields[2], 65535);
    guard let port = port_result else {
        return err("mongo.connect: malformed SRV port");
    }
    if port < 1 || fields[3] == "." {
        return err("mongo.connect: SRV service is unavailable");
    }
    let target = mongo_normalize_dns_name(fields[3]);
    if !mongo_dns_host_valid(target) ||
       !mongo_srv_target_allowed(uri_host, target) {
        return err("mongo.connect: SRV target is outside the URI domain");
    }
    return ok(MongoSeed { host: target, port: port });
}

fn mongo_srv_target_allowed(uri_host: str, target: str) -> bool {
    let source = mongo_normalize_dns_name(uri_host);
    let labels = strings.split(source, ".");
    let domain = source;
    if len(labels) >= 3 {
        let first_dot = strings.find(source, ".");
        if first_dot < 1 { return false; }
        domain = strings.slice(source, first_dot + 1, len(source));
    }
    return target != domain && strings.has_suffix(target, "." + domain);
}

fn mongo_normalize_dns_name(name: str) -> str {
    let normalized = strings.to_lower(name);
    if strings.has_suffix(normalized, ".") {
        return strings.slice(normalized, 0, len(normalized) - 1);
    }
    return normalized;
}

fn mongo_parse_unsigned(raw: str, max_value: int) -> opt[int] {
    if raw == "" { return none; }
    let encoded = to_bytes(raw);
    let value = 0;
    for b in encoded {
        if b < 48 || b > 57 { return none; }
        let digit = b - 48;
        if value > (max_value - digit) / 10 { return none; }
        value = value * 10 + digit;
    }
    return some(value);
}
