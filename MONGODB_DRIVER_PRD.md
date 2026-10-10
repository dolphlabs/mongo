# MongoDB Driver for slang — PRD

**Status:** Approved scope; implementation in progress.
**Repository:** `github.com/dolphlabs/mongo`
**Import name:** `mongodb`
**Planned package path:** `src/mongodb/`

## Product goal

Provide an independently versioned, installable MongoDB client for slang backend services. Applications should add one Git/tag pin in `slang.project`, import `mongodb`, and use the language's existing `net` package for non-blocking database I/O. The driver should make safe limits, TLS verification, deadlines, and explicit errors part of its contract.

The compiler already resolves external package pins by Git URL, tag, and source directory; the short package name remains the application import. The planned install shape is therefore one `mongodb` pin pointing at this repository's `src/mongodb` directory. The initial driver needs one compiler-provided primitive for lossless BSON Double values: `encoding.float64_to_le` and `encoding.float64_from_le`. That prerequisite is being added to the `slang` repository separately; the driver will use it rather than implementing floating-point bit conversion in slang arithmetic.

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

## Non-goals for the first milestone

Transactions, change streams, load-balanced mode, sharded-cluster routing, automatic retryable writes, and a complete aggregation-builder DSL are excluded unless selected as launch requirements. A raw command API can expose server features without a driver-specific builder for each one.

The first release targets one direct `mongodb://` host. Replica-set discovery,
multiple seed hosts, and `mongodb+srv://` are deferred. The initial operation
surface includes raw commands, common insert/find/update/delete helpers,
cursors, and a bounded connection pool.

## Proposed architecture

- Keep the driver in this repository as a pure slang package under `src/mongodb/`.
- Use `net.dial_until`, `net.recv_until`, and `net.send_until`; close a connection after an I/O timeout or malformed frame because the stream position is no longer trustworthy.
- Use MongoDB's modern message format and strict message framing. Validate declared lengths, section kinds, request/response identifiers, and all BSON boundaries before allocating or indexing.
- Keep URI parsing strict: reject malformed escapes and unsupported or misspelled options instead of ignoring them.
- Set explicit configurable caps for wire messages, BSON documents, cursor batches, nesting, and aggregate decoded values.
- Use TLS certificate-chain and hostname verification whenever TLS is enabled. Never offer a “TLS but skip identity checks” mode as a secure default.
- Keep the API's BSON representation and the client/connection lifecycle explicit. Avoid hidden implicit connections or unbounded response buffering.

## Proposed delivery milestones

1. **Package foundation and BSON:** project metadata, reusable BSON value/document API, bounded encoder/decoder, and malformed-input tests. Requires a slang compiler release containing the binary64 helpers above.
2. **Single-server command client:** URI parsing, TCP/TLS, SCRAM-SHA-256, handshake, command request/response, server errors, deadlines, and fake-server tests.
3. **Backend operations:** agreed CRUD helpers, cursor/getMore/killCursors lifecycle, bounded batches, and a connection pool with FIFO waiters and safe shutdown.
4. **Cluster connectivity:** replica-set discovery and primary selection; add `mongodb+srv` only if selected, because SRV/TXT lookup is not exposed by the existing slang `net` API and may require a separate compiler/runtime change.
5. **Measurement and release:** codec and database-path benchmark against the official Go driver on the same MongoDB instance and host; report throughput, p50/p99 latency, CPU, and RSS before making performance claims.

The delivery order can change with the scope decision below. A direct single-server first release is smaller, but it does not provide replica-set failover or Atlas SRV URI support.

## Security and compatibility requirements

- Treat every URI component, server message, BSON length, count, cursor id, and reply as untrusted.
- Fail closed on unsupported authentication mechanisms, malformed SCRAM exchanges, invalid TLS certificates, unexpected protocol frames, and unknown URI options.
- Do not retry a write after an ambiguous timeout unless the selected retry contract can prove whether it is safe.
- Do not expose passwords in errors, logs, or debug output.
- Keep tests deterministic and independent of a running MongoDB service. Add an opt-in integration suite for a pinned server version.
- Maintain an explicit supported server-version range and BSON type matrix in the README before publishing a release.

## Validation and release gates

- A regression test must demonstrate each protocol or safety defect before the fix and pass after it.
- Exercise URI parsing, BSON round trips, numeric boundaries, nested and oversized documents, truncated frames, bad lengths, request-id mismatches, command errors, timeouts, authentication failures, TLS verification, pool wakeups, and connection reuse.
- Run `slangc test` for the package and a consumer fixture that pins the repository by Git/tag and imports `mongodb`.
- Run live MongoDB integration tests separately from the default suite.
- Measure any claimed performance change using repeated, interleaved runs against Go on the same host and database; include p99 and RSS as well as throughput.
- Publish versioned tags only after docs, license, supported-version policy, and clean-install verification are complete.

## Standards and source-use note

The MongoDB wire protocol reference documents the command framing and modern message format. MongoDB's published specifications repository states its specifications are licensed CC BY-NC-SA. This project should not copy or adapt that material into its source or tests. Implement original slang code and validate interoperability with a real server and a separately licensed driver. See the [wire protocol reference](https://www.mongodb.com/docs/manual/reference/mongodb-wire-protocol/) and [specifications repository](https://github.com/mongodb/specifications).

Authentication and TLS behavior should be checked against the official [MongoDB authentication documentation](https://www.mongodb.com/docs/languages/c/c-driver/current/security/authentication/) and [TLS documentation](https://www.mongodb.com/docs/drivers/go/current/security/tls/). Do not copy driver implementation code unless its license and required attribution are deliberately handled.

## Decisions recorded before driver implementation

1. **BSON/document API — decided:** Expose a dynamic `Document`/`Value` model in the standalone package. Typed-struct codecs can be considered later, likely through generated codecs or compiler support; the package itself cannot reflect over arbitrary struct fields at runtime.
2. **Topology — decided:** Support one direct `mongodb://` endpoint first. Defer replica-set discovery, multiple seeds, and `mongodb+srv://` until the language exposes the required DNS and topology support.
3. **Operation surface — decided:** Include raw commands, basic insert/find/update/delete helpers, cursor iteration, and a connection pool in the first usable release.

**License:** MIT, matching the slang compiler repository.
