# mongo

Standalone MongoDB driver package for slang. The repository and project name is
`mongo`; applications import its package as `mongo` from `src/mongo`.
Socket waits use slang's non-blocking `net` package.

The API supports direct `mongodb://` connections and initial seed discovery
through `mongodb+srv://`, verified TLS, SCRAM-SHA-256, raw commands, CRUD,
aggregation cursors, sessions, replica-set transactions, and a bounded
connection pool. It remains pre-release and has no stable tag.

## Features and limits

- BSON `Document` and dynamic `Value` types, plus bounded encode/decode for
  Double, String, Document, Array, Binary, ObjectId, Boolean, DateTime, Null,
  Regex, Int32, Timestamp, Int64, Decimal128, MinKey, and MaxKey. Unsupported
  legacy BSON tags return errors. Decimal128 remains its 16 wire bytes and has
  no arithmetic API.
- Strict URI parsing for one direct `mongodb://` host or one
  `mongodb+srv://` DNS name, percent-encoded credentials/database,
  `authSource`, `authMechanism=SCRAM-SHA-256`, `tls`, `tlsCAFile`, and
  `appName`. SRV URIs also accept `replicaSet` and `srvServiceName`. Unknown
  and duplicate options, explicit SRV ports, and host lists are rejected.
- SRV URIs query SRV and optional TXT records under the caller's deadline,
  validate every seed against the URI hostname's parent domain, and try seeds
  until a writable primary is found. SRV priority and weight are ignored.
  TLS is enabled by default for SRV URIs; `tls=false` is an explicit override.
  TXT records may set only `authSource`, `replicaSet`, and `loadBalanced`;
  URI options override TXT defaults. `loadBalanced=true` is rejected.
- Initial seed discovery runs when a connection is opened. The driver does not
  yet monitor topology changes, reconnect after failover, or provide automatic
  retryable writes.
- Deadline-bounded TCP/TLS connect, handshake, authentication, commands, and
  cursor reads. TLS verifies the certificate chain and host name.
- `command`/`command_on`, insert/find/update/delete helpers, `find_one`, and
  cursors with `getMore` and `killCursors`. `aggregate` and `pool_aggregate`
  accept `[Document]` stages and return the same bounded `Cursor` type; no
  stage-builder DSL is required.
- `start_session` and `pool_start_session` create explicit sessions. Session
  collections and commands carry `lsid`; `begin_transaction`,
  `commit_transaction`, and `abort_transaction` support replica-set
  transactions. A pooled session pins one connection until `end_session`.
  Use each session sequentially; concurrent operations on one session are
  unsupported. Commit errors can have an unknown outcome, and the driver does
  not retry commits or writes automatically.
- The FIFO pool allows at most 1,024 open connections and defaults to 10,000
  queued waiters; use `new_pool_config_with_limits` to lower the waiter cap.
- Default caps of 16 MiB per BSON document, 48 MiB per wire message, 100 nested
  levels, and 100,000 BSON values per document. `new_limits` configures codec
  limits, while `Config.max_bson_bytes` and `Config.max_message_bytes` may be
  lowered for a connection.

slang's `float` is an IEEE-754 binary64 value. BSON Double uses the compiler
helpers `encoding.float64_to_le` and `encoding.float64_from_le`; use a slang
compiler build that includes those helpers. The compiler change is being
tracked separately and must land before this package can be consumed from a
release compiler.

Atlas SRV support also requires a compiler that provides the deadline-bounded
`net.lookup_srv_until` and `net.lookup_txt_until` functions. Their implementation
is in the companion slang compiler change.

SCRAM-SHA-256 credentials are currently limited to printable ASCII. Non-ASCII
credentials are rejected because slang does not yet provide the Unicode
normalization required by SASLprep. This avoids silently deriving the wrong
password key. Decimal128 is preserved losslessly but is not interpreted.
BSON strings containing U+0000 remain lossless through `string_bytes_value`
and `as_string_bytes`; `as_string` returns an error because slang `str` is
NUL-terminated.

The decoder refuses duplicate document keys and non-sequential BSON array
indexes rather than making field lookup or array order ambiguous. `put`
replaces an existing field in place, so it preserves document order without
creating duplicate keys.

## Install after release

After the first tagged release, add this pin to an application `slang.project`:

```text
pkg mongo git https://github.com/dolphlabs/mongo.git tag v0.1.0 dir src/mongo
```

Then run `slangc get` and import `mongo` from slang source. Until a release is
tagged, the API and install pin are not stable.

## Example

```slang
import "mongo";

let user = mongo.document();
let id = mongo.int32_value(42);
guard let id_value = id else let e = err_of(id) { panic(e); }
let saved = mongo.put(user, "id", id_value);
guard let _saved = saved else let e = err_of(saved) { panic(e); }
let body = mongo.encode(user);
guard let raw = body else let e = err_of(body) { panic(e); }
```

For a connection, create one absolute deadline and pass it through the whole
operation:

```slang
import "mongo";
import "time";

let deadline = until_of(time.mono() + 5_000_000_000);
let connected = mongo.connect("mongodb+srv://cluster.example.mongodb.net/app", deadline);
guard let db = connected else let e = err_of(connected) { panic(e); }
let target = mongo.collection(db, "users");
guard let users = target else let e = err_of(target) { panic(e); }
let filter = mongo.document();
let found = mongo.find_one(users, filter, deadline);
guard let maybe_user = found else let e = err_of(found) { panic(e); }
if let user = maybe_user {
    let name = mongo.get(user, "name");
}
mongo.close_conn(db);
```

Use `new_pool`/`new_pool_config` for concurrent requests. Always call
`cursor_close` when stopping cursor iteration early. Always call
`release(pool, connection)` after an explicit `acquire`; pool operation helpers
manage checkout and release. Exhaust or close every session cursor before
committing, aborting, or ending its session.

Build aggregation stages directly from BSON documents:

```slang
let match_filter = mongo.document();
let added = mongo.put(match_filter, "active", mongo.bool_value(true));
guard let _added = added else let e = err_of(added) { panic(e); }
let match_stage = mongo.document();
let stage_added = mongo.put(match_stage, "$match",
                            mongo.document_value(match_filter));
guard let _stage = stage_added else let e = err_of(stage_added) { panic(e); }
let pipeline: [mongo.Document] = [];
push(pipeline, match_stage);
let cursor = mongo.aggregate(users, pipeline, 100, deadline);
```

For transactions, acquire a session from the pool, get its collection handle,
then explicitly begin and commit or abort. Pooled sessions occupy one pool slot
until `end_session`. Transactions require a writable-primary connection to a
replica set; sharded routing and `mongos` are not supported.

For Atlas and other DNS seed-list deployments, pass a `mongodb+srv://` URI to
`connect` or `new_pool`. The hostname must be one DNS name without a port.
Connection setup resolves `_mongodb._tcp.<hostname>` and optional TXT defaults
before opening any socket. It validates all returned seed names against the
inferred parent domain, then tries seeds in resolver order until the server
reports itself as writable primary. This is initial discovery; the current
driver does not poll SRV records or transparently recover from topology
changes. A single absolute deadline covers DNS and every dial and handshake
attempt. See [MONGO_DRIVER_PRD.md](MONGO_DRIVER_PRD.md) for the driver's scope
and remaining release gates.

## Compatibility and tests

The live integration suite is pinned to MongoDB 8.2.12. It verifies SCRAM over
TLS with a generated local CA, rejects wrong credentials and an untrusted CA,
checks aggregation over multiple batches, and commits and aborts a transaction
on a one-node replica set. Other server versions have not been qualified. The
driver does not monitor topology changes or recover from failover; Atlas SRV
support performs initial DNS seed discovery only.

The slang compiler must provide `encoding.float64_to_le`,
`encoding.float64_from_le`, and, for SRV URIs, deadline-bounded
`net.lookup_srv_until` and `net.lookup_txt_until`.

Run the deterministic protocol and BSON suite with `slangc test -v src/mongo`.
It uses scripted loopback peers and needs no MongoDB server. Smoke-test the
package import from `tests/consumer` with `slangc main.sl --run`. Run the
opt-in real-server checks with `tests/live/run.sh`; Docker and OpenSSL are
required. The script creates temporary authenticated/TLS and replica-set
containers, test collections, and certificates, then removes them.

The in-memory BSON codec benchmark compares this package with the official Go
MongoDB BSON codec v1.17.10 on the same document and host. Run
`bench/bson/run.sh` with a compiler containing the binary64 encoding helpers.
The output includes a hash of each encoded fixture to confirm wire parity.
That codec benchmark measures serialization cost only. The sorted-range
client comparison and its measured limits are recorded in
[`MONGO_DRIVER_PRD.md`](MONGO_DRIVER_PRD.md); it is a local Mac/Docker diagnostic,
not a cloud service benchmark. The current decoder is still slower than Go on
that workload, despite the reduction in allocation, instructions, and RSS.

## Design notes

See [MONGO_DRIVER_PRD.md](MONGO_DRIVER_PRD.md) for scope, remaining work,
test requirements, security boundaries, and source-use notes.

## License

MIT. See [LICENSE](LICENSE).
