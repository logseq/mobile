#!/usr/bin/env bash
# Run the real Swift runtime with an injected core boundary, without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
if [[ "${LOGSEQ_IOS_SKIP_BUILD:-0}" != "1" ]]; then
  scripts/build-mobile-ios-simulator.sh
fi
python3 apple/Tests/UI/run-simulator-runtime-check.py apple/Tests/UI/outliner-autosave.swift Check
