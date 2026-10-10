#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SLANGC=${SLANGC:-slangc}
MONGO_SRC=${MONGO_SRC:-$ROOT/src/mongodb}

if ! command -v "$SLANGC" >/dev/null 2>&1; then
    echo "run.sh: set SLANGC to a compiler containing encoding.float64_* helpers" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mongo-bson-bench.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
cp "$ROOT/bench/bson/main.sl" "$TMP_DIR/main.sl"
ln -s "$MONGO_SRC" "$TMP_DIR/mongodb"
cd "$TMP_DIR"
uname -a
"$SLANGC" --version
go version
"$SLANGC" main.sl -o /tmp/mongo-bson-slang
(
    cd "$ROOT/bench/bson/go"
    go build -o /tmp/mongo-bson-go .
)

echo "ABBA codec benchmark; results are local measurements, not database latency."
/tmp/mongo-bson-slang
/tmp/mongo-bson-go
/tmp/mongo-bson-go
/tmp/mongo-bson-slang
