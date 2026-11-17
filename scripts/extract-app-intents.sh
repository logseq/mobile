#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module=$1
sdk=$2
triple=$3
deployment_target=$4
output=$5
swift_build_dir=$6
swift_scratch_dir=$7
shift 7
work=$(mktemp -d /tmp/logseq-app-intents.XXXXXX)
trap 'rm -rf "$work"' EXIT
module_cache="$repo_root/apple/.build/app-intents-module-cache"
mkdir -p "$module_cache"
sources=("$@")
# SwiftPM normally supplies these Clang modules when importing Logseq.
sentry_headers="$swift_scratch_dir/checkouts/sentry-cocoa/Sources/Sentry"
compiler_options=(
  -I "$swift_build_dir/Modules"
  -Xcc "-fmodule-map-file=$swift_build_dir/LogseqCoreABI.build/module.modulemap"
  -I "$repo_root/apple/Sources/LogseqCoreABI/include"
  -Xcc "-fmodule-map-file=$swift_build_dir/SentryHeaders.build/module.modulemap"
  -I "$sentry_headers/Public"
  -I "$sentry_headers/include"
)
printf '%s\n' "${sources[@]}" > "$work/sources"
printf '%s\n' "$work/values.swiftconstvalues" > "$work/values"
started=$SECONDS
xcrun swiftc -frontend -typecheck -parse-as-library -sdk "$sdk" -target "$triple" \
  -module-cache-path "$module_cache" \
  -module-name "$module" -const-gather-protocols-file "$repo_root/scripts/app-intents-protocols.json" \
  -emit-const-values-path "$work/values.swiftconstvalues" "${compiler_options[@]}" "${sources[@]}"
echo "[ios-build] App Intents typecheck and constants: $((SECONDS - started))s" >&2
started=$SECONDS
xcrun appintentsmetadataprocessor --output "$output" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name "$module" --sdk-root "$sdk" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family iOS --deployment-target "$deployment_target" --target-triple "$triple" \
  --source-file-list "$work/sources" --swift-const-vals-list "$work/values"
[[ -s "$output/Metadata.appintents/extract.actionsdata" ]]
echo "[ios-build] App Intents metadata: $((SECONDS - started))s" >&2
