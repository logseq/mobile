#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
cat > "$temporary/module.modulemap" <<EOF
module LogseqCoreABI {
  header "$repo_root/apple/Sources/LogseqCoreABI/include/LogseqCoreABI.h"
  export *
}
EOF
xcrun swiftc -parse-as-library -I "$temporary" \
  "$repo_root/apple/Sources/LogseqModel/CoreExecutor.swift" \
  "$repo_root/apple/Tests/UI/core-executor-autorelease.swift" \
  -o "$temporary/check"
"$temporary/check"
