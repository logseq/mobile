#!/usr/bin/env bash
# Verify real attachment taps and native Quick Look presentation without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
check_dir=$(mktemp -d)
simulator=${LOGSEQ_IOS_SIMULATOR:-$(xcrun simctl list devices booted --json | python3 -c \
  'import json,sys; print(next(device["udid"] for devices in json.load(sys.stdin)["devices"].values() for device in devices if device["state"] == "Booted"))')}
export LOGSEQ_IOS_SIMULATOR="$simulator"
runtime_pid=
cleanup() {
  [[ -z "$runtime_pid" ]] || kill "$runtime_pid" 2>/dev/null || true
  xcrun simctl terminate "$simulator" com.logseq.logseq.RuntimeCheck >/dev/null 2>&1 || true
  rm -rf "$check_dir"
}
trap cleanup EXIT
LOGSEQ_RUNTIME_CHECK_TIMEOUT=120 python3 apple/Tests/UI/run-simulator-runtime-check.py \
  apple/Tests/UI/asset-file-preview.swift AssetFilePreviewCheck >"$check_dir/runtime.log" 2>&1 &
runtime_pid=$!
if ! maestro --device "$simulator" test \
  --debug-output "$check_dir/maestro" apple/Tests/UI/asset-file-preview.yaml; then
  cat "$check_dir/runtime.log"
  exit 1
fi
if ! wait "$runtime_pid"; then
  cat "$check_dir/runtime.log"
  exit 1
fi
runtime_pid=
cat "$check_dir/runtime.log"
