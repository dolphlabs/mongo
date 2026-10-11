# mongo — MongoDB driver for slang

**Status:** Core driver, aggregation cursors, replica-set transactions, and the pinned live suite are implemented. Sorted-range decoding improved measurably, but its Go performance target remains open. A clean Git-pinned consumer install and release tag remain.
**Repository:** `github.com/dolphlabs/mongo`
**Import name:** `mongo`
**Planned package path:** `src/mongo/`

## Product goal

Provide an independently versioned, installable MongoDB client for slang backend services. Applications should add one Git/tag pin in `slang.project`, import `mongo`, and use the language's existing `net` package for non-blocking database I/O. The driver should make safe limits, TLS verification, deadlines, and explicit errors part of its contract.

The compiler already resolves external package pins by Git URL, tag, and source directory; the short package name remains the application import. The planned install shape is therefore one `mongo` pin pointing at this repository's `src/mongo` directory. The driver needs one compiler-provided primitive for lossless BSON Double values: `encoding.float64_to_le` and `encoding.float64_from_le`. That prerequisite is being implemented in a separate `slang` compiler change; the driver uses it rather than implementing floating-point bit conversion in slang arithmetic.

## Project understanding

At project start, this repository was an empty Git repository. slang packages are directories of `.sl` files compiled into one package namespace. Existing `pg` and `redis` clients are written in slang over `net`; that lets socket waits park a slang task rather than block a worker thread. The standard library provides deadline-bounded TCP/TLS operations, cryptographic primitives, byte encodings, and `result[_, str]` errors.

There is no existing BSON package, dynamic JSON value model, MongoDB protocol implementation, or Mongo integration test suite. JSON serialization targets concrete slang types; it does not supply the dynamic, type-preserving value model a general document database driver needs. The BSON document API is therefore a first-order public API decision, not an implementation detail.

## Goals

- Ship a standalone slang package that applications can pin and lock without copying files into the compiler repository.
- Encode/decode BSON with type fidelity and strict bounds on document size, nesting, element count, and allocated reply data.
- Speak the current MongoDB command protocol over TCP, with absolute deadlines for connect, authentication, commands, and cursor reads.
- Support authenticated connections and verified TLS without silently downgrading security.
- Expose a low-level command path so applications can use MongoDB features before every operation has a convenience wrapper.
- Add common collection operations and cursor handling at the agreed initial scope.
- Test hostile and malformed protocol input with scripted fake servers; keep live-server tests opt-in.

## Deliberate limits

The package exposes MongoDB pipeline stages as BSON documents instead of adding
a fluent aggregation DSL. It supports explicit replica-set sessions and
transactions, but does not route sharded transactions through `mongos`. Direct
connections and initial `mongodb+srv://` seed discovery are supported; ongoing
topology monitoring, failover recovery, automatic retryable writes, change
streams, and load-balanced mode remain out of scope. Session operations must
run sequentially on a given Session.

## Proposed architecture

- Keep the driver in this repository as a pure slang package under `src/mongo/`.
- Use `net.dial_until`, `net.recv_until`, and `net.send_until`; close a connection after an I/O timeout or malformed frame because the stream position is no longer trustworthy.
- Use MongoDB's modern message format and strict message framing. Validate declared lengths, section kinds, request/response identifiers, and all BSON boundaries before allocating or indexing.
- Keep URI parsing strict: reject malformed escapes and unsupported or misspelled options instead of ignoring them.
- Set explicit configurable caps for wire messages, BSON documents, cursor batches, nesting, and aggregate decoded values.
- Use TLS certificate-chain and hostname verification whenever TLS is enabled. Never offer a “TLS but skip identity checks” mode as a secure default.
- Keep the API's BSON representation and the client/connection lifecycle explicit. Avoid hidden implicit connections or unbounded response buffering.

## Delivery milestones

1. **Package foundation and BSON — implemented:** metadata, dynamic BSON API, bounded encoder/decoder, and malformed-input tests. A compiler build with the separate binary64 helpers is required.
2. **Single-server command client — implemented:** URI parsing, TCP/TLS, SCRAM-SHA-256, handshake, OP_MSG commands, server errors, deadlines, and scripted-peer tests.
3. **Backend operations — implemented:** insert/find/update/delete helpers, cursor getMore/killCursors, bounded batches, and FIFO connection pooling with waiter limits and shutdown.
4. **Aggregation and transactions — implemented:** pipeline cursors support
   `$match`, `$sort`, `$group`, `$project`, `getMore`, and cursor cleanup.
   Sessions carry `lsid`; transaction commands carry `txnNumber`,
   `autocommit`, and the first-operation marker. Pooled sessions pin one
   connection until ended. Scripted tests cover malformed replies, cursor
   cleanup, transaction isolation, and explicit commit retry after an unknown
   result.
5. **Live interoperability — implemented for MongoDB 8.2.12:**
   `tests/live/run.sh` builds temporary TLS/SCRAM and one-node replica-set
   servers. It passed verified TLS, authentication, aggregation with a second
   batch, transaction commit, and abort/rollback on 2026-10-11. Other server
   versions and Atlas itself have not been qualified.
6. **Cluster connectivity — initial discovery implemented:** `mongodb+srv`
   URI parsing, bounded SRV/TXT resolution, seed validation, TXT defaults,
   and initial writable-primary selection are available. Automatic topology
   monitoring, failover, retryable writes, and load-balanced mode remain out
   of scope. This package change depends on the companion compiler change for
   `net.lookup_srv_until` and `net.lookup_txt_until`.
7. **Measurement — sorted-range optimization measured (2026-10-11):** eight
   read-only samples per implementation and worker count compared the pre-change
   decoder, current decoder, and Go on the same MongoDB 8.2.12 dataset. The
   dataset contains 500,000 documents with 1 KiB payloads and the `_id_`,
   `tenant_seq`, and `status_tenant` indexes. Each request returns and validates
   50 sorted documents. At 16 workers, current median throughput is 1,082.5
   req/s versus 685 for the old decoder and 2,762.5 for Go; current p50/p99 is
   11.50/42.47 ms versus 19.38/56.03 ms before and 5.22/12.76 ms for Go. Median
   client RSS fell from 63.52 to 48.98 MiB and retired instructions from 58.23
   to 32.02 billion. The local Mac/Docker result is diagnostic, not a cloud
   server benchmark. The optimization is substantial but does not meet the
   original 98%-of-Go throughput and 1.02x-Go p99 goal.

## Current API and remaining work

`aggregate(collection, pipeline, batch_size, deadline)` and
`pool_aggregate(pool, collection_name, pipeline, batch_size, deadline)` accept
`[Document]` stages and return the bounded cursor used by `find`. The cursor
keeps batches bounded, sends `getMore` as needed, and can kill a live cursor
when closed early.

`start_session` and `pool_start_session` create sessions. `session_collection`
and `session_command` attach the session id to commands. Transactions use
`begin_transaction`, `commit_transaction`, and `abort_transaction`, followed by
`end_session`. A pooled Session holds its connection until it ends. Transactions
are restricted to a writable primary in a replica set. The API does not retry
ambiguous commits automatically; returned errors preserve MongoDB error labels
so callers can decide whether to retry commit with the same Session.

The next performance task is further reducing the remaining sorted-range cost.
The current implementation validates incoming UTF-8 once, stores ordinary
BSON strings as slang strings, and reuses decoded batch arrays rather than
copying them. The table reports medians over eight read-only samples per build
and worker count; each request checks 50 returned documents.

| Workers | Build | Requests/s | p50 (ms) | p99 (ms) | RSS (MiB) | Retired instructions (B) |
|---:|---|---:|---:|---:|---:|---:|
| 1 | Before | 225.5 | 4.371 | 5.618 | 18.78 | 3.60 |
| 1 | Current slang | 351.0 | 2.757 | 3.780 | 12.02 | 2.00 |
| 1 | Go | 953.5 | 0.993 | 1.756 | 13.28 | 0.35 |
| 16 | Before | 685.0 | 19.377 | 56.034 | 63.52 | 58.23 |
| 16 | Current slang | 1,082.5 | 11.501 | 42.473 | 48.98 | 32.02 |
| 16 | Go | 2,762.5 | 5.224 | 12.757 | 16.42 | 5.76 |

At 16 workers the change improved throughput 58%, p99 24%, RSS 23%, and retired
instructions 45% against the pre-change decoder. It reaches 39% of Go
throughput and has 3.3x Go p99. At one worker it reaches 37% of Go throughput
with 2.2x Go p99. Do not claim parity until a new measured change closes that
gap without increasing memory unsafely.

Release work remains: run a clean Git-pinned consumer install after publishing
the source branch, qualify any additional MongoDB versions before claiming
them, and create a version tag only after those checks pass. The current
validated server point is 8.2.12; no broader compatibility range is claimed.

## Security and compatibility requirements

- Treat every URI component, server message, BSON length, count, cursor id, and reply as untrusted.
- Fail closed on unsupported authentication mechanisms, malformed SCRAM exchanges, invalid TLS certificates, unexpected protocol frames, and unknown URI options.
- Do not retry a write after an ambiguous timeout unless the selected retry contract can prove whether it is safe.
- Do not expose passwords in errors, logs, or debug output.
- Keep tests deterministic and independent of a running MongoDB service. Add an opt-in integration suite for a pinned server version.
- Maintain the tested MongoDB version and BSON type matrix in the README before publishing a release.

## Validation and release gates

- A regression test must demonstrate each protocol or safety defect before the fix and pass after it.
- Exercise URI parsing, BSON round trips, numeric boundaries, nested and oversized documents, truncated frames, bad lengths, request-id mismatches, command errors, timeouts, authentication failures, TLS verification, pool wakeups, and connection reuse.
- Run `slangc test -v src/mongo`, the local consumer smoke test, and
  `tests/live/run.sh` separately.
- Before tagging, run a clean-cache consumer fixture pinned to the pushed
  source, then repeat with the release tag.
- Measure any claimed performance change using repeated, interleaved runs against Go on the same host and database; include p99 and RSS as well as throughput.
- Publish versioned tags only after docs, license, supported-version policy, and clean-install verification are complete.

## Standards and source-use note

The MongoDB wire protocol reference documents the command framing and modern message format. MongoDB's published specifications repository states its specifications are licensed CC BY-NC-SA. This project should not copy or adapt that material into its source or tests. Implement original slang code and validate interoperability with a real server and a separately licensed driver. See the [wire protocol reference](https://www.mongodb.com/docs/manual/reference/mongo-wire-protocol/) and [specifications repository](https://github.com/mongodb/specifications).

Authentication and TLS behavior should be checked against the official [MongoDB authentication documentation](https://www.mongodb.com/docs/languages/c/c-driver/current/security/authentication/) and [TLS documentation](https://www.mongodb.com/docs/drivers/go/current/security/tls/). Do not copy driver implementation code unless its license and required attribution are deliberately handled.

## Decisions recorded before driver implementation

1. **BSON/document API — decided:** Expose a dynamic `Document`/`Value` model. Typed-struct codecs can be considered later through generated codecs or compiler support; the package cannot reflect over arbitrary struct fields at runtime.
2. **Topology — current:** Direct endpoints and bounded `mongodb+srv://` seed discovery are supported. Failover monitoring and sharded routing are deferred.
3. **Operation surface — current:** Raw commands, CRUD, cursors, aggregation pipelines, explicit sessions and replica-set transactions, and a bounded connection pool are implemented.

**License:** MIT, matching the slang compiler repository.
