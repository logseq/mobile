#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -O apple/Sources/Logseq/LGImageCompression.swift \
  apple/Sources/Logseq/LGAssetImporter.swift apple/Sources/Logseq/SharedCapture.swift \
  apple/Tests/ImageCompression/ImageCompressionChecks.swift -o "$check_dir/check"
"$check_dir/check" "${1:-$check_dir/fixtures}"
