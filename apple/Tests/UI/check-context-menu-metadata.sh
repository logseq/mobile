#!/usr/bin/env bash
# Exercise context-menu patch validation and action dispatch without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
simulator=${1:?Pass a booted simulator UDID}
scratch=.build/snapshot-http-check-ios
triple=arm64-apple-ios17.0-simulator
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --scratch-path "$scratch" --product Logseq --disable-sandbox \
  -Xswiftc -enable-testing --triple "$triple" --sdk "$sdk"
build_dir=$(swift build --scratch-path "$scratch" --disable-sandbox \
  --triple "$triple" --sdk "$sdk" --show-bin-path)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$triple" \
  -I "$build_dir/Modules" -I "$build_dir/LogseqCoreABI.build" \
  Tests/UI/context-menu-metadata.swift "$build_dir/libLogseq.a" \
  -o "$check_dir/check"
xcrun simctl spawn "$simulator" "$check_dir/check"
