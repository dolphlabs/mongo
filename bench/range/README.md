# Sorted BSON range benchmark

This benchmark compares the existing dynamic BSON cursor with the opt-in
`DocumentView` cursor and the official Go MongoDB driver. It only issues
sorted `find` operations; it never seeds, updates, or deletes records.

The database must already contain an `events` collection with 500,000
documents, 1 KiB string payloads, and the `tenant_seq` index on
`{tenant_id: 1, seq: 1}`. Each measured operation returns 50 records and checks
the tenant, sorted sequence, and payload length. Set `MONGO_URI` to that
database. `bench/range/run.sh` builds the slang and Go programs, then
`run.py` executes eight samples of each implementation per worker count in
interleaved ABBA order. Results and per-run system resource output are written
under `/tmp`; nothing is written to MongoDB.

```sh
MONGO_URI='mongodb://127.0.0.1:27017/slang_mongo_bench_20261011_final' \
  bench/range/run.sh
```

Use `WORKERS` and `OPS` to change the default worker counts `1,16` and 100
operations per worker. The Slang benchmark can emit collector counters for a
separate allocation profile with `SLANG_GC_STAT=1`; do not enable this during
the throughput/latency comparison because diagnostic counters add overhead.
On macOS, `/usr/bin/time -l` records RSS and retired instructions. On Linux,
the runner records RSS using GNU `time -v`; use `perf stat -e instructions` on
a host where hardware counters are permitted.
