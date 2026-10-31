#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN="$ROOT/.build/fispr-wlow-tests"
mkdir -p "$ROOT/.build"
swiftc -parse-as-library -D FISPR_TEST "$ROOT/Sources/ModelCatalog.swift" "$ROOT/Sources/FisprWlow.swift" "$ROOT/Tests/main.swift" \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework CoreGraphics -framework Speech \
  -o "$BIN"
"$BIN" --self-test
python3 -m unittest discover -s "$ROOT/Tests" -p 'test_*.py' -v
