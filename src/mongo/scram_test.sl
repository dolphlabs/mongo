import "encoding";
import "strings";

fn test_mongo_scram_sha256_rfc7677_vector() {
    let server_first =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," +
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    let proof_result = mongo_scram_client_proof(
        "user", "pencil", "rOprNGfwEbeRWgbNEkqO", server_first);
    guard let proof = proof_result else let e = err_of(proof_result) { panic(e); }
    assert(to_str(proof.payload) ==
           "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," +
           "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=");
    assert(encoding.base64_encode(proof.server_signature) ==
           "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
}

fn test_mongo_scram_escapes_sasl_username() {
    let server_first = "r=nonce-server,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    let proof_result = mongo_scram_client_proof("a,b=c", "pencil", "nonce",
                                         server_first);
    guard let proof = proof_result else let e = err_of(proof_result) { panic(e); }
    assert(strings.has_prefix(to_str(proof.payload), "c=biws,r=nonce-server,p="));
}

fn test_mongo_scram_rejects_unsafe_or_hostile_challenges() {
    let nonce = "rOprNGfwEbeRWgbNEkqO";
    let bad_nonce = mongo_scram_client_proof("user", "pencil", nonce,
        "r=attacker,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    if let _proof = bad_nonce {
        panic("SCRAM accepted a server nonce that did not extend the client nonce");
    }
    let weak = mongo_scram_client_proof("user", "pencil", nonce,
        "r=rOprNGfwEbeRWgbNEkqOserver,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1");
    if let _proof = weak {
        panic("SCRAM accepted a weak iteration count");
    }
    let huge = mongo_scram_client_proof("user", "pencil", nonce,
        "r=rOprNGfwEbeRWgbNEkqOserver,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000001");
    if let _proof = huge {
        panic("SCRAM accepted an excessive iteration count");
    }
    let duplicate = mongo_scram_client_proof("user", "pencil", nonce,
        "r=rOprNGfwEbeRWgbNEkqOserver,r=again,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    if let _proof = duplicate {
        panic("SCRAM accepted a duplicate server attribute");
    }
    let non_ascii_password = to_str(b"p\xc3\xa9ncil");
    let non_ascii = mongo_scram_client_proof("user", non_ascii_password, nonce,
        "r=rOprNGfwEbeRWgbNEkqOserver,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    if let _proof = non_ascii {
        panic("SCRAM silently accepted a password requiring SASLprep");
    }
}
