import "mongo";
import "time";

let doc = mongo.document();
let identifier = mongo.int32_value(42);
guard let id = identifier else let e = err_of(identifier) { panic(e); }
let added = mongo.put(doc, "id", id);
guard let _added = added else let e = err_of(added) { panic(e); }
let raw_result = mongo.encode(doc);
guard let raw = raw_result else let e = err_of(raw_result) { panic(e); }
let decoded_result = mongo.decode(raw);
guard let decoded = decoded_result else let e = err_of(decoded_result) { panic(e); }
let got = mongo.get(decoded, "id");
guard let value = got else { panic("consumer lost id field"); }
let number_result = mongo.as_int32(value);
guard let number = number_result else let e = err_of(number_result) { panic(e); }
assert(number == 42);
println("mongo consumer ok");

fn compile_client_api(uri: str, deadline: until) -> result[bool, str] {
    let connected = mongo.connect(uri, deadline);
    guard let db = connected else let e = err_of(connected) { return err(e); }
    let target = mongo.collection(db, "users");
    guard let users = target else let e = err_of(target) {
        mongo.close_conn(db);
        return err(e);
    }
    let filter = mongo.document();
    let found = mongo.find_one(users, filter, deadline);
    guard let maybe_user = found else let e = err_of(found) {
        mongo.close_conn(db);
        return err(e);
    }
    if let user = maybe_user {
        let name = mongo.get(user, "name");
    }
    mongo.close_conn(db);
    return ok(true);
}
