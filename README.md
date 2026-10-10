# MongoDB driver for slang

This repository contains an independently versioned slang MongoDB package at
`src/mongodb`. The API uses ordered BSON documents and dynamic, type-tagged
values. It is designed to run database waits through slang's non-blocking
`net` package.

The package is under development. The first release targets one direct
`mongodb://` endpoint and plans to include verified TLS, SCRAM-SHA-256, raw
commands, common CRUD operations, cursors, and a bounded connection pool.
Replica-set discovery and `mongodb+srv://` are deferred.

## Package status

The current implementation work is the BSON value model and bounded BSON
encoder/decoder. It supports Double, String, Document, Array, Binary, ObjectId,
Boolean, DateTime, Null, Regex, Int32, Timestamp, Int64, Decimal128, MinKey, and
MaxKey. Unsupported legacy BSON tags fail with an error. Decimal128 is kept as
its 16 wire bytes; the package does not yet provide decimal arithmetic.

slang's `float` is an IEEE-754 binary64 value. BSON Double uses the compiler
helpers `encoding.float64_to_le` and `encoding.float64_from_le`; use a slang
compiler release that includes those helpers.

The default BSON limits are 16 MiB per document, 100 nested levels, and 100,000
values across one encode/decode. `new_limits` makes those bounds configurable;
the codec still validates bounds and every wire length before indexing or
allocating from it. BSON strings containing U+0000 remain lossless through
`string_bytes_value` and `as_string_bytes`; `as_string` returns an error for
those values because slang `str` is NUL-terminated.

The decoder refuses duplicate document keys and non-sequential BSON array
indexes rather than making field lookup or array order ambiguous. `put`
replaces an existing field in place, so it preserves document order without
creating duplicate keys.

## Planned install

After the first tagged release, add this pin to an application `slang.project`:

```text
pkg mongodb git https://github.com/dolphlabs/mongo.git tag v0.1.0 dir src/mongodb
```

Then run `slangc get` and import `mongodb` from slang source. Until a release is
tagged, the API and install pin are not stable.

## BSON example

```slang
import "mongodb";

let user = mongodb.document();
let id = mongodb.int32_value(42);
guard let id_value = id else let e = err_of(id) { panic(e); }
let saved = mongodb.put(user, "id", id_value);
guard let _saved = saved else let e = err_of(saved) { panic(e); }
let body = mongodb.encode(user);
guard let raw = body else let e = err_of(body) { panic(e); }
```

## Design notes

See [MONGODB_DRIVER_PRD.md](MONGODB_DRIVER_PRD.md) for scope, staged delivery,
test requirements, security boundaries, and source-use notes.

## License

MIT. See [LICENSE](LICENSE).
