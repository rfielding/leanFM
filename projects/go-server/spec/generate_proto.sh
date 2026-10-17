#!/usr/bin/env bash
# generate_proto.sh - generate Go proto stubs from spec/Requirements.proto
# Requires: protoc and protoc-gen-go in PATH
set -euo pipefail
ROOTDIR=$(dirname "$0")/..
PROTO=spec/Requirements.proto
OUTDIR=api

mkdir -p "$OUTDIR"
protoc --go_out="$OUTDIR" --go_opt=paths=source_relative "$PROTO"

echo "generated proto stubs into $OUTDIR"
