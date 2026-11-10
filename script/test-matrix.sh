#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DART_BIN="${DART_BIN:-dart}"
if ! command -v "$DART_BIN" >/dev/null || ! command -v cargo >/dev/null; then
  echo "The matrix requires Dart (set DART_BIN if needed) and Cargo." >&2
  exit 1
fi
export BOOKALOG_RUN_NATIVE_MATRIX=1
bash script/test.sh
