fn mongo_test_parse_uri(uri: str) -> Config {
    let parsed = parse_uri(uri);
    guard let cfg = parsed else let e = err_of(parsed) {
        panic(e);
    }
    return cfg;
}

fn mongo_test_uri_error(uri: str) -> str {
    let parsed = parse_uri(uri);
    guard let _cfg = parsed else let e = err_of(parsed) {
        return e;
    }
    panic("invalid MongoDB URI was accepted");
}

fn test_mongo_uri_defaults_and_direct_host() {
    let cfg = mongo_test_parse_uri("mongodb://localhost");
    assert(cfg.host == "localhost");
    assert(cfg.port == 27017);
    assert(cfg.database == "test");
    assert(cfg.auth_source == "admin");
    assert(cfg.username == "" && cfg.password == "");
    assert(!cfg.tls && cfg.ca_file == "");
    assert(cfg.max_bson_bytes == 16777216);
    assert(cfg.max_message_bytes == 50331648);
}

fn test_mongo_uri_credentials_database_and_options() {
    let cfg = mongo_test_parse_uri(
        "mongodb://app%40user:p%3Ass%40word@db.example:27018/orders?authSource=admin&tls=true&appName=svc");
    assert(cfg.host == "db.example" && cfg.port == 27018);
    assert(cfg.database == "orders" && cfg.auth_source == "admin");
    assert(cfg.username == "app@user" && cfg.password == "p:ss@word");
    assert(cfg.tls && cfg.app_name == "svc");
    assert(cfg.auth_mechanism == "SCRAM-SHA-256");
}

fn test_mongo_uri_ipv6_and_percent_decoded_database() {
    let cfg = mongo_test_parse_uri("mongodb://[::1]:27019/team%20db?directConnection=true");
    assert(cfg.host == "::1" && cfg.port == 27019);
    assert(cfg.database == "team db");
    assert(cfg.auth_source == "admin");
}

fn test_mongo_uri_tls_ca_file_enables_verified_tls() {
    let cfg = mongo_test_parse_uri("mongodb://db.example/orders?tlsCAFile=%2Fetc%2Fmongo-ca.pem");
    assert(cfg.tls && cfg.ca_file == "/etc/mongo-ca.pem");
}

fn test_mongo_srv_uri_defaults_and_overrides() {
    let cfg = mongo_test_parse_uri("mongodb+srv://Cluster.Example.com/orders");
    assert(cfg.srv && cfg.host == "cluster.example.com");
    assert(cfg.port == 27017 && cfg.database == "orders");
    assert(cfg.tls && cfg.srv_service_name == "mongodb");
    assert(cfg.auth_source == "admin" && !cfg.auth_source_explicit);
    let dotted = mongo_test_parse_uri("mongodb+srv://CLUSTER.example.com./db");
    assert(dotted.host == "cluster.example.com");

    let override = mongo_test_parse_uri(
        "mongodb+srv://user:pass@cluster.example.com/orders?authSource=authdb&replicaSet=rs0&tls=false&srvServiceName=custom-db");
    assert(override.srv && !override.tls);
    assert(override.auth_source == "authdb" && override.auth_source_explicit);
    assert(override.replica_set == "rs0" && override.replica_set_explicit);
    assert(override.srv_service_name == "custom-db");
}

fn test_mongo_uri_rejects_ambiguous_or_unsupported_hosts() {
    assert(mongo_test_uri_error("mongodb+srv://cluster.example:27017/db") != "");
    assert(mongo_test_uri_error("mongodb+srv://one.example,two.example/db") != "");
    assert(mongo_test_uri_error("mongodb+srv://-bad.example/db") != "");
    assert(mongo_test_uri_error("mongodb+srv://cluster.example/db?directConnection=true") != "");
    assert(mongo_test_uri_error("mongodb+srv://cluster.example/db?loadBalanced=true") != "");
    assert(mongo_test_uri_error("mongodb://cluster.example/db?srvServiceName=custom") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?loadBalanced=true") != "");
    assert(mongo_test_uri_error("mongodb://db1,db2/db") != "");
    assert(mongo_test_uri_error("mongodb://2001:db8::1/db") != "");
    assert(mongo_test_uri_error("mongodb://[::1") != "");
    assert(mongo_test_uri_error("mongodb://db.example:27017x/db") != "");
    assert(mongo_test_uri_error("mongodb:///db") != "");
}

fn test_mongo_srv_txt_defaults_and_option_errors() {
    let cfg = mongo_test_parse_uri("mongodb+srv://cluster.example.com/db");
    let applied = mongo_apply_srv_txt(
        cfg, "authSource=dnsAuth&replicaSet=dnsRs&loadBalanced=false");
    guard let _ok = applied else let e = err_of(applied) { panic(e); }
    assert(cfg.auth_source == "dnsAuth");
    assert(cfg.replica_set == "dnsRs");
    assert(!cfg.load_balanced);

    let override = mongo_test_parse_uri(
        "mongodb+srv://user:pass@cluster.example.com/orders?authSource=uriAuth&replicaSet=uriRs&loadBalanced=false");
    let overridden = mongo_apply_srv_txt(
        override, "authSource=dnsAuth&replicaSet=dnsRs&loadBalanced=true");
    guard let _override_ok = overridden else let e = err_of(overridden) { panic(e); }
    assert(override.auth_source == "uriAuth");
    assert(override.replica_set == "uriRs");
    assert(!override.load_balanced);

    assert(mongo_test_txt_error(cfg, "ssl=true") != "");
    assert(mongo_test_txt_error(cfg, "appName=api") != "");
    assert(mongo_test_txt_error(cfg, "authSource=a&authSource=b") != "");
    assert(mongo_test_txt_error(cfg, "authSource") != "");
    assert(mongo_test_txt_error(cfg, "loadBalanced=maybe") != "");
}

fn mongo_test_txt_error(cfg: Config, raw: str) -> str {
    let applied = mongo_apply_srv_txt(cfg, raw);
    guard let _ok = applied else let e = err_of(applied) { return e; }
    panic("invalid MongoDB TXT options were accepted");
}

fn test_mongo_srv_record_target_validation() {
    let parsed = mongo_parse_srv_seed(
        "cluster.example.com", "0:99:27018:Node.cluster.example.com.");
    guard let seed = parsed else let e = err_of(parsed) { panic(e); }
    assert(seed.host == "node.cluster.example.com" && seed.port == 27018);

    let two_label_seed = mongo_parse_srv_seed(
        "cluster.example", "0:0:27017:node.cluster.example.");
    guard let _valid = two_label_seed else let e = err_of(two_label_seed) { panic(e); }
    assert(mongo_test_srv_error("cluster.example.com", "0:0:27017:evil-example.com") != "");
    assert(mongo_test_srv_error("cluster.example.com", "0:0:27017:node.other.net") != "");
    assert(mongo_test_srv_error("cluster.example.com", "65536:0:27017:node.cluster.example.com") != "");
    assert(mongo_test_srv_error("cluster.example.com", "0:0:0:node.cluster.example.com") != "");
    assert(mongo_test_srv_error("cluster.example.com", "0:0:27017:.") != "");
    assert(mongo_test_srv_error("cluster.example.com", "0:0:27017x:node.cluster.example.com") != "");
}

fn mongo_test_srv_error(uri_host: str, record: str) -> str {
    let parsed = mongo_parse_srv_seed(uri_host, record);
    guard let _seed = parsed else let e = err_of(parsed) { return e; }
    panic("invalid MongoDB SRV record was accepted");
}

fn test_mongo_uri_rejects_bad_credentials_and_query_options() {
    assert(mongo_test_uri_error("mongodb://user%ZZ@db.example/db") != "");
    assert(mongo_test_uri_error("mongodb://user:p%00ss@db.example/db") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db/other") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?tls=true&TLS=false") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?tls=false&tlsCAFile=%2Fca.pem") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?tlsCAFile=%2Fca.pem&tls=false") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?tlsInsecure=true") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?replicaSet=rs0") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?authMechanism=PLAIN") != "");
    assert(mongo_test_uri_error("mongodb://db.example/db?tls=maybe") != "");
}
