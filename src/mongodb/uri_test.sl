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

fn test_mongodb_uri_defaults_and_direct_host() {
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

fn test_mongodb_uri_credentials_database_and_options() {
    let cfg = mongo_test_parse_uri(
        "mongodb://app%40user:p%3Ass%40word@db.example:27018/orders?authSource=admin&tls=true&appName=svc");
    assert(cfg.host == "db.example" && cfg.port == 27018);
    assert(cfg.database == "orders" && cfg.auth_source == "admin");
    assert(cfg.username == "app@user" && cfg.password == "p:ss@word");
    assert(cfg.tls && cfg.app_name == "svc");
    assert(cfg.auth_mechanism == "SCRAM-SHA-256");
}

fn test_mongodb_uri_ipv6_and_percent_decoded_database() {
    let cfg = mongo_test_parse_uri("mongodb://[::1]:27019/team%20db?directConnection=true");
    assert(cfg.host == "::1" && cfg.port == 27019);
    assert(cfg.database == "team db");
    assert(cfg.auth_source == "admin");
}

fn test_mongodb_uri_tls_ca_file_enables_verified_tls() {
    let cfg = mongo_test_parse_uri("mongodb://db.example/orders?tlsCAFile=%2Fetc%2Fmongo-ca.pem");
    assert(cfg.tls && cfg.ca_file == "/etc/mongo-ca.pem");
}

fn test_mongodb_uri_rejects_ambiguous_or_unsupported_hosts() {
    assert(mongo_test_uri_error("mongodb+srv://cluster.example/db") != "");
    assert(mongo_test_uri_error("mongodb://db1,db2/db") != "");
    assert(mongo_test_uri_error("mongodb://2001:db8::1/db") != "");
    assert(mongo_test_uri_error("mongodb://[::1") != "");
    assert(mongo_test_uri_error("mongodb://db.example:27017x/db") != "");
    assert(mongo_test_uri_error("mongodb:///db") != "");
}

fn test_mongodb_uri_rejects_bad_credentials_and_query_options() {
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
