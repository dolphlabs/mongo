#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SLANGC=${SLANGC:-slangc}
GO=${GO:-go}
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mongo-range-bench.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

if ! command -v "$SLANGC" >/dev/null 2>&1; then
    echo "run.sh: slangc was not found" >&2
    exit 1
fi
if ! command -v "$GO" >/dev/null 2>&1; then
    echo "run.sh: Go was not found" >&2
    exit 1
fi

cp "$ROOT/bench/range/main.sl" "$TMP_DIR/main.sl"
ln -s "$ROOT/src/mongo" "$TMP_DIR/mongo"
cd "$TMP_DIR"
"$SLANGC" main.sl -o "$TMP_DIR/slang-bench"
"$GO" -C "$ROOT/bench/range/go" build -o "$TMP_DIR/go-bench" .
"$SLANGC" --version
"$GO" version
echo "Read-only sorted-range ABBA comparison; no MongoDB records are written."
SLANG_BENCH="$TMP_DIR/slang-bench" GO_BENCH="$TMP_DIR/go-bench" \
    python3 "$ROOT/bench/range/run.py"
