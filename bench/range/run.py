#!/usr/bin/env python3
import json
import os
import pathlib
import re
import statistics
import subprocess
import sys
import tempfile
import urllib.parse


def parse_result(output):
    lines = [line for line in output.splitlines() if line.startswith("RESULT ")]
    if not lines:
        raise RuntimeError("benchmark emitted no RESULT line")
    line = lines[-1]
    fields = {}
    for name in ("workers", "ops", "elapsed_ns", "throughput_ops_s",
                 "p50_ns", "p95_ns", "p99_ns", "checks", "errors"):
        match = re.search(rf"(?:^| ){name}=(\d+)(?: |$)", line)
        if match:
            fields[name] = int(match.group(1))
    fields["raw"] = line
    return fields


def read_resources(path):
    if not path.exists():
        return None, None
    text = path.read_text(errors="replace")
    rss = None
    instructions = None
    match = re.search(r"(\d+)\s+maximum resident set size", text)
    if match:
        rss = int(match.group(1))
    else:
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
        if match:
            rss = int(match.group(1)) * 1024
    match = re.search(r"(\d+)\s+instructions retired", text)
    if match:
        instructions = int(match.group(1))
    return rss, instructions


def timed_command(command, resource_path):
    time_bin = pathlib.Path("/usr/bin/time")
    if sys.platform == "darwin" and time_bin.exists():
        return [str(time_bin), "-l", "-o", str(resource_path), *command]
    if time_bin.exists():
        return [str(time_bin), "-v", "-o", str(resource_path), *command]
    return command


def main():
    uri = os.environ.get("MONGO_URI", "mongodb://127.0.0.1:27017/slang_mongo_bench_20261011_final")
    parsed = urllib.parse.urlsplit(uri)
    database = os.environ.get("MONGO_DATABASE") or urllib.parse.unquote(
        parsed.path.lstrip("/").split("/", 1)[0]
    ) or "test"
    workers = [int(value) for value in os.environ.get("WORKERS", "1,16").split(",")]
    ops = int(os.environ.get("OPS", "100"))
    reps = int(os.environ.get("REPS", "4"))
    slang_bin = os.environ.get("SLANG_BENCH")
    go_bin = os.environ.get("GO_BENCH")
    if not slang_bin or not go_bin:
        raise SystemExit("set SLANG_BENCH and GO_BENCH to the compiled read-only benchmark binaries")
    if not workers or any(value < 1 or value > 128 for value in workers) or ops < 1 or reps < 1:
        raise SystemExit("WORKERS must be 1..128; OPS and REPS must be positive")

    out_dir = pathlib.Path(os.environ.get("OUT_DIR") or tempfile.mkdtemp(prefix="mongo-range-results-"))
    resources_dir = out_dir / "resources"
    resources_dir.mkdir(parents=True, exist_ok=True)
    results_path = out_dir / "results.jsonl"
    results = []
    orders = [
        ("dynamic", "view", "go", "go", "view", "dynamic"),
        ("go", "view", "dynamic", "dynamic", "view", "go"),
    ]

    for worker_count in workers:
        counts = {"dynamic": 0, "view": 0, "go": 0}
        for repetition in range(reps):
            order = orders[repetition % len(orders)]
            for label in order:
                counts[label] += 1
                sample = counts[label]
                name = f"{worker_count}-{sample}-{label}"
                resource_path = resources_dir / f"{name}.txt"
                if label == "go":
                    command = [go_bin, "-uri", uri, "-database", database,
                               "-workers", str(worker_count), "-ops", str(ops)]
                    lang, decoder = "go", "go"
                else:
                    command = [slang_bin, "--uri", uri, "--decoder", label,
                               "--workers", str(worker_count), "--ops", str(ops)]
                    lang, decoder = "slang", label
                proc = subprocess.run(timed_command(command, resource_path),
                                      text=True, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE)
                if proc.returncode:
                    error = proc.stderr.replace(uri, "[MONGO_URI]")
                    raise SystemExit(f"FAIL {name}\n{proc.stdout}\n{error}")
                fields = parse_result(proc.stdout)
                expected_checks = worker_count * ops * 50
                if fields.get("checks") != expected_checks or fields.get("errors") != 0:
                    raise SystemExit(f"correctness failed for {name}: {fields['raw']}")
                rss, instructions = read_resources(resource_path)
                row = {
                    "lang": lang,
                    "decoder": decoder,
                    "workers": worker_count,
                    "sample": sample,
                    **fields,
                    "rss_bytes": rss,
                    "instructions": instructions,
                }
                results.append(row)
                with results_path.open("a") as handle:
                    handle.write(json.dumps(row) + "\n")
                print(f"{name}: {fields['raw']}", flush=True)

    for worker_count in workers:
        print(f"MEDIANS workers={worker_count}")
        for label in ("dynamic", "view", "go"):
            group = [row for row in results
                     if row["workers"] == worker_count and row["decoder"] == label]
            summary = {}
            for key in ("throughput_ops_s", "p50_ns", "p99_ns", "rss_bytes", "instructions"):
                values = [row[key] for row in group if row[key] is not None]
                summary[key] = statistics.median(values) if values else None
            print(f"  {label}: {summary}")
    print(f"PASS {len(results)} read-only samples; checks passed; results={results_path}")


if __name__ == "__main__":
    main()
