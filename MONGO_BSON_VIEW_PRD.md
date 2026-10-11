# MongoDB BSON view performance PRD

**Status:** Implemented and measured. The opt-in view path improves the sorted-range database path while preserving full BSON validation and the default `Document` API. Go parity remains open.
**Repository:** `github.com/dolphlabs/mongo`
**Branch:** `perf/mongo-bson-view`

## Project understanding

`mongo` is a standalone slang package built over the language's non-blocking
`net` client. Its wire layer reads one bounded OP_MSG response, validates the
frame, and decodes the BSON command body. `bson_decode.sl` uses an explicit
heap-backed frame stack so hostile nesting does not consume the 8 KB task
stack. It produces a dynamic `Document`/`Value` tree and enforces byte, depth,
value-count, UTF-8, duplicate-key, and array-index limits.

`operations.sl` represents each cursor batch as `[Value]`. `cursor_next`
unwraps one decoded document at a time, but the full reply batch has already
been materialized. A sorted-range application that reads only a few fields
therefore still creates values for every returned field. The official Go
MongoDB driver decodes only the fields the application asks it to inspect.

The existing range result is a local diagnostic, not a cloud benchmark. It
uses MongoDB 8.2.12 with 500,000 documents, 1 KiB payloads, three indexes, and
50 sorted results per operation. Its last eight-sample medians at 16 workers
were 1,082.5 requests/s, 42.47 ms p99, 48.98 MiB RSS, and 32.02 billion retired
instructions for slang, compared with 2,762.5 requests/s, 12.76 ms p99,
16.42 MiB, and 5.76 billion instructions for Go. Every sample validated all
50 returned records. The previous decoder optimization reduced slang's
instructions and allocations but did not close the Go gap.

## Problem

The sorted-range path remained much slower and used more memory than Go even
after avoiding repeated string validation and retaining decoded string
storage. Profiling confirmed the BSON response decoder as a major cost: the
dynamic implementation allocated about 100.8 MB and 751,932 objects for 100
operations. A selective view path was therefore implemented and measured.

## Goal

Provide an opt-in way to read a few fields from BSON documents without
materializing every BSON value. Keep the existing `Document`, `Value`, and
cursor interfaces unchanged. The implementation is retained because the same
sorted-range workload showed higher throughput, lower p99, lower RSS, and
fewer retired instructions, with all correctness checks passing.

## Proposed design

- Add an immutable `DocumentView` that retains the validated response bytes
  and the byte range of one BSON document. A view does not copy the BSON
  document or build a `Field`/`Value` tree.
- Add typed, bounds-checked accessors for common fields, including integer,
  string length, string, boolean, and nested document access. Accessors report
  a type error rather than coercing BSON values.
- Add opt-in `find_view` and `pool_find_view` cursor operations for sorted
  range reads. Existing `find`, `pool_find`, `decode`, and `Document` APIs
  retain their current behavior.
- Validate the complete OP_MSG frame and every BSON element before exposing a
  view. Preserve all current byte, depth, value-count, UTF-8, duplicate-key,
  and array-index checks. Unused values may avoid allocation, but are never
  skipped by validation.
- Views keep their source response batch alive. Document this retention cost;
  replacing a cursor batch releases it when callers no longer retain views.

The database-facing cursor parses the OP_MSG frame from split header/body
buffers, validates the complete BSON response, and stores byte ranges in
`DocumentView`/`ValueView`. It uses an iterative validator so hostile nesting
does not consume task stack. The returned view pins its source bytes; the
cursor drops its own reference to exhausted batches, and caller-held views
retain the full batch they reference. `view_string_len` reads a string's byte
length without materializing it. `view_as_binary` returns an independent copy
of the payload because slang `bytes` slices copy their data.

## Out of scope

- Replacing or changing the existing `Document`/`Value` public representation.
- Relaxing validation, silently accepting duplicate BSON keys, or trusting
  malformed server responses.
- A projection builder, aggregation DSL, topology monitor, or server-side
  query change.
- Claims of Go parity based on codec-only timing or throughput without p99,
  RSS, and per-sample correctness.

## Measurement and acceptance

1. Profile BSON allocations and CPU for the existing 50-result sorted range.
2. Compare the unchanged decoder with the view path in ABBA order at 1 and 16
   workers on the same MongoDB dataset and host. Keep the read-only query,
   payload checks, sample count, and Go binary fixed.
3. Record medians and raw samples for throughput, p50, p99, RSS, retired
   instructions, GC allocations, and correctness checks.
4. Require zero errors and exactly 50 valid results for every operation.
   Reject malformed and over-limit BSON with the same strict behavior as the
   existing decoder.
5. Keep the new API only if the sorted-range measurements improve both
   throughput and p99 beyond the observed sample spread, while reducing
   decoder allocations or RSS. Explain any memory retained by long-lived
   views.

## Verification

- Add tests for all view accessors, wrong types, missing fields, nested
  documents, invalid UTF-8, duplicate keys, truncation, depth/value/byte
  limits, and retained source-buffer correctness.
- Run the deterministic BSON/protocol test suite and consumer compile.
- Run the existing live MongoDB 8.2.12 suite where Docker is available.
- Update `README.md` and `MONGO_DRIVER_PRD.md` only after the API and benchmark
  outcome are settled.

## Results (2026-10-11)

Eight read-only samples per path and worker count ran in ABBA order against the
same local MongoDB 8.2.12 dataset. Each operation returned 50 sorted records
and checked tenant id, increasing sequence, and the 1,024-byte payload length.
All 48 samples passed, with 5,000 checks per one-worker sample and 80,000 per
16-worker sample. These are local Mac/Docker measurements, not cloud results.
Raw per-sample results are preserved in
`bench/range/results_20261011_mac.jsonl`.

| Workers | Path | Requests/s | p50 (ms) | p99 (ms) | RSS (MiB) | Retired instructions (B) |
|---:|---|---:|---:|---:|---:|---:|
| 1 | Dynamic slang | 352.5 | 2.787 | 3.361 | 11.90 | 2.00 |
| 1 | BSON view slang | 526.0 | 1.862 | 2.481 | 6.26 | 1.29 |
| 1 | Go | 938.5 | 0.998 | 1.575 | 13.20 | 0.35 |
| 16 | Dynamic slang | 1,031.0 | 12.755 | 42.883 | 50.50 | 32.09 |
| 16 | BSON view slang | 1,610.5 | 7.783 | 32.102 | 18.66 | 20.13 |
| 16 | Go | 2,861.5 | 5.008 | 12.190 | 15.98 | 5.77 |

At 16 workers, view throughput improved 56%, p99 fell 25%, RSS fell 63%, and
retired instructions fell 37% relative to dynamic slang. View throughput is
56% of Go's, and view p99 is 2.63 times Go's. At one worker, view throughput
is 56% of Go's and p99 is 1.57 times Go's.

A separate diagnostic run of 100 operations measured 751,932 allocations and
100,775,999 allocated bytes for dynamic decoding, versus 391,682 allocations
and 45,771,665 bytes for the view path. This reduces allocation count 47.9%
and allocated bytes 54.6%; GC diagnostic counters were not enabled in the
throughput/latency runs. `/usr/bin/sample` also placed the prior hot path in
`mongo_command_on`, `mongo_decode_op_msg`, `decode_with_limits`, and
`bson_decode_scalar`, including frequent UTF-8 validation.

The view API closes a meaningful part of the gap but does not meet the original
98%-of-Go throughput and 1.02x-Go p99 goal. The next performance step should
profile command round trips, repeated key lookups, and server/driver costs
before expanding this API further.

The consumer smoke passed with the new API. Against the pre-change package,
the same consumer fails compilation at `decode_view` because that function is
absent. The deterministic suite passed 42 tests with
`SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16` and zero missed references;
the live MongoDB 8.2.12 TLS/auth, sorted view `getMore`, aggregation, and
replica-set transaction suite also passed.
