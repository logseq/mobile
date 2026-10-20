#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Keep developer signing defaults out of checks that intentionally omit them.
export LOGSEQ_IOS_CONFIG=/tmp/logseq-device-script-check-no-config
export LOGSEQ_IOS_BUNDLE_ID=com.logseq.logseq.script-check
unset LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE LOGSEQ_IOS_PROFILE

failures=0

if ! grep -Fq 'scripts/build-mobile-ocaml.sh' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build does not delegate OCaml compilation to Dune" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'LOGSEQ_IOS_KEYCHAIN' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build cannot select an isolated signing keychain" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'restore_keychain_search_list' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build does not restore the signing keychain search list" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'security list-keychains -d user -s' \
  "$repo_root/scripts/build-mobile-ios-device.sh"; then
  echo "not ok - device build does not add its signing keychain to the search list" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'NSAllowsLocalNetworking' \
  "$repo_root/scripts/configure-ios-info-plist.sh"; then
  echo "not ok - iOS app does not allow an explicitly configured local API" >&2
  failures=$((failures + 1))
fi

if ! grep -q 'NSLocalNetworkUsageDescription' \
  "$repo_root/scripts/configure-ios-info-plist.sh"; then
  echo "not ok - iOS app does not explain local network access" >&2
  failures=$((failures + 1))
fi

ios_e2e_script="$repo_root/scripts/test-ios-e2e.sh"
ios_e2e_suite_script="$repo_root/scripts/test-ios-e2e-suite.sh"
simulator_build_script="$repo_root/scripts/build-mobile-ios-simulator.sh"

if ! grep -q 'swift_scratch_dir=' "$simulator_build_script"; then
  echo "not ok - simulator build does not define its Swift scratch directory" >&2
  failures=$((failures + 1))
fi

for build_script in "$repo_root/scripts/build-mobile-ios-device.sh" "$simulator_build_script"; do
  if ! grep -q 'prune_stale_swift_resource_bundles' "$build_script"; then
    echo "not ok - iOS build does not prune stale SwiftPM resource bundles: $build_script" >&2
    failures=$((failures + 1))
  fi
done

for extension in LogseqShareExtension LogseqWidgets; do
  if ! grep -Fq "$extension.appex" "$simulator_build_script"; then
    echo "not ok - simulator build does not embed $extension" >&2
    failures=$((failures + 1))
  fi
done

if ! grep -Fq 'PlugIns' "$simulator_build_script"; then
  echo "not ok - simulator build does not create the app extension directory" >&2
  failures=$((failures + 1))
fi

if ! grep -Fq \
  'base_url=${LOGSEQ_E2E_BASE_URL:-http://127.0.0.1:8787}' \
  "$ios_e2e_script"; then
  echo "not ok - iOS Simulator E2E does not default to the local API" >&2
  failures=$((failures + 1))
fi

if grep -Fq 'api-staging.logseq.io' "$ios_e2e_script"; then
  echo "not ok - iOS Simulator E2E embeds the staging API" >&2
  failures=$((failures + 1))
fi

for required_flow in \
  'tests/e2e/ios-outliner-editor-toolbar.yaml' \
  'tests/e2e/ios-outliner-continuous-editing.yaml' \
  'tests/e2e/ios-outliner-selection-toolbar.yaml' \
  'tests/e2e/ios-outliner-hierarchy-navigation.yaml' \
  'tests/e2e/ios-graphs-lifecycle.yaml'; do
  if ! grep -Fq "$required_flow" "$ios_e2e_suite_script"; then
    echo "error: iOS E2E suite is missing $required_flow" >&2
    exit 1
  fi
done

for marker in \
  'tests/e2e/ios-local-graph-setup.yaml' \
  '__LOGSEQ_E2E_SETUP_FLOW__' \
  'sync.checkpoint' \
  'waiting for the graph snapshot import to finish'; do
  if ! grep -Fq "$marker" "$ios_e2e_script"; then
    echo "not ok - iOS Simulator E2E omits local graph setup: $marker" >&2
    failures=$((failures + 1))
  fi
done

device_build_script="$repo_root/scripts/build-mobile-ios-device.sh"

if grep -q 'rm -f "$swift_build_dir/LogseqShell"' "$device_build_script"; then
  echo "not ok - device build unconditionally discards the incremental Swift link" >&2
  failures=$((failures + 1))
fi

for marker in \
  'native_link_fingerprint=$(' \
  'native-link-inputs/$native_link_fingerprint' \
  'native_link_inputs=' \
  'swift_scratch_dir=${LOGSEQ_IOS_SWIFT_SCRATCH_PATH:-$repo_root/apple/.build/ios-device}' \
  '--scratch-path "$swift_scratch_dir"'; do
  if ! grep -Fq -- "$marker" "$device_build_script"; then
    echo "not ok - device build does not content-address native link inputs: $marker" >&2
    failures=$((failures + 1))
  fi
done

native_fingerprint_block=$(sed -n \
  '/native_link_fingerprint=$(/,/^)/p' \
  "$device_build_script")
for input in \
  '$core_object' \
  '$https_object' \
  '$crypto_object' \
  '$ocaml_lib/libthreadsnat.a'; do
  if [[ $native_fingerprint_block != *"$input"* ]]; then
    echo "not ok - native link fingerprint omits input: $input" >&2
    failures=$((failures + 1))
  fi
done

check_rejects() {
  local name=$1
  local expected=$2
  shift 2

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    echo "not ok - $name: command succeeded" >&2
    failures=$((failures + 1))
    return
  fi

  if [[ $output != *"$expected"* ]]; then
    echo "not ok - $name: expected '$expected'" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_succeeds() {
  local name=$1
  local expected=$2
  shift 2

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "not ok - $name: command failed" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  if [[ $output != *"$expected"* ]]; then
    echo "not ok - $name: expected '$expected'" >&2
    echo "$output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_succeeds \
  "device build accepts production bundle settings without building" \
  "configuration=debug" \
  env LOGSEQ_IOS_BUNDLE_ID=com.logseq.logseq \
    LOGSEQ_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_rejects \
  "device install refuses production Logseq bundle id" \
  "refusing to install over the production Logseq bundle id" \
  env LOGSEQ_IOS_BUNDLE_ID=com.logseq.logseq \
    "$repo_root/scripts/install-mobile-ios-device.sh"

check_rejects \
  "device build requires a provisioning profile" \
  "set LOGSEQ_IOS_PROFILE to a development provisioning profile for com.logseq.logseq" \
  env -u LOGSEQ_IOS_PROFILE \
    LOGSEQ_IOS_CONFIG=/tmp/logseq-missing-device-config \
    "$repo_root/scripts/build-mobile-ios-device.sh"

fake_device_config=$(mktemp /tmp/logseq-ios-device-config.XXXXXX)
cat >"$fake_device_config" <<'CONFIG'
LOGSEQ_IOS_PROFILE=/tmp/logseq-development.mobileprovision
LOGSEQ_IOS_SIGNING_IDENTITY="Apple Development: Tiansheng Qin (T6PA4U4765)"
CONFIG

check_succeeds \
  "device build remembers local signing defaults" \
  "profile=/tmp/logseq-development.mobileprovision signing-identity=Apple Development: Tiansheng Qin (T6PA4U4765)" \
  env -u LOGSEQ_IOS_PROFILE \
    -u LOGSEQ_IOS_SIGNING_IDENTITY \
    LOGSEQ_IOS_CONFIG="$fake_device_config" \
    LOGSEQ_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_succeeds \
  "device build selects release configuration" \
  "configuration=release swift-build-dir=$repo_root/apple/.build/ios-device/arm64-apple-ios/release" \
  env LOGSEQ_IOS_BUILD_CONFIGURATION=release \
    LOGSEQ_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_succeeds \
  "device build keeps debug configuration available" \
  "configuration=debug swift-build-dir=$repo_root/apple/.build/ios-device/arm64-apple-ios/debug" \
  env LOGSEQ_IOS_BUILD_CONFIGURATION=debug \
    LOGSEQ_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_rejects \
  "device build rejects unsupported configuration" \
  "unsupported iOS build configuration: profile" \
  env LOGSEQ_IOS_BUILD_CONFIGURATION=profile \
    LOGSEQ_IOS_PRINT_BUILD_SETTINGS=1 \
    "$repo_root/scripts/build-mobile-ios-device.sh"

check_rejects \
  "device install requires a provisioning profile" \
  "set LOGSEQ_IOS_PROFILE to a development provisioning profile for com.logseq.logseq" \
  env -u LOGSEQ_IOS_PROFILE \
    LOGSEQ_IOS_CONFIG=/tmp/logseq-missing-device-config \
    "$repo_root/scripts/install-mobile-ios-device.sh"

fake_profile=$(mktemp /tmp/logseq-fake-mobileprovision.XXXXXX)
fake_bin=$(mktemp -d /tmp/logseq-fake-bin.XXXXXX)
cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "devicectl list devices" ]]; then
  device_state=${FAKE_DEVICE_STATE:-unavailable}
  cat <<'DEVICES'
Name        Hostname                           Identifier                             State                Model
---------   --------------------------------   ------------------------------------   ------------------   ---------------------------
DEVICES
  printf 'iPhone      iPhone.coredevice.local            ACC1F5DA-71E4-560F-9818-FC6B1517D6A0   %s          iPhone 15 (iPhone15,4)\n' "$device_state"
  exit 0
fi

echo "unexpected xcrun invocation: $*" >&2
exit 42
SH
chmod +x "$fake_bin/xcrun"

check_rejects \
  "device install reports unavailable target before build" \
  "target iOS device 'iPhone' is unavailable" \
  env PATH="$fake_bin:$PATH" \
    LOGSEQ_IOS_PROFILE="$fake_profile" \
    LOGSEQ_IOS_DEVICE=iPhone \
    "$repo_root/scripts/install-mobile-ios-device.sh"

check_rejects \
  "device install accepts connected target" \
  "unexpected xcrun invocation: --sdk iphoneos --show-sdk-path" \
  env PATH="$fake_bin:$PATH" \
    FAKE_DEVICE_STATE=connected \
    LOGSEQ_IOS_PROFILE="$fake_profile" \
    LOGSEQ_IOS_DEVICE=iPhone \
    "$repo_root/scripts/install-mobile-ios-device.sh"

check_rejects \
  "device install accepts available target" \
  "unexpected xcrun invocation: --sdk iphoneos --show-sdk-path" \
  env PATH="$fake_bin:$PATH" \
    FAKE_DEVICE_STATE=available \
    LOGSEQ_IOS_PROFILE="$fake_profile" \
    LOGSEQ_IOS_DEVICE=iPhone \
    "$repo_root/scripts/install-mobile-ios-device.sh"

check_rejects \
  "profile creation refuses production Logseq bundle id" \
  "refusing to create a profile for the production Logseq bundle id" \
  env LOGSEQ_IOS_BUNDLE_ID=com.logseq.logseq \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

check_rejects \
  "profile creation requires API key id" \
  "set APP_STORE_CONNECT_API_KEY_ID" \
  env -u APP_STORE_CONNECT_API_KEY_ID \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

check_rejects \
  "profile creation requires API issuer id" \
  "set APP_STORE_CONNECT_ISSUER_ID" \
  env -u APP_STORE_CONNECT_ISSUER_ID \
    APP_STORE_CONNECT_API_KEY_ID=fake-key-id \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

check_rejects \
  "profile creation requires API private key file" \
  "App Store Connect API key file was not found" \
  env APP_STORE_CONNECT_API_KEY_PATH=/tmp/logseq-missing-auth-key.p8 \
    APP_STORE_CONNECT_API_KEY_ID=fake-key-id \
    APP_STORE_CONNECT_ISSUER_ID=fake-issuer-id \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

fake_key=$(mktemp /tmp/logseq-fake-auth-key.XXXXXX)
cat >"$fake_key" <<'KEY'
-----BEGIN PRIVATE KEY-----
fake
-----END PRIVATE KEY-----
KEY

check_succeeds \
  "profile creation dry run ensures bundle id before profile" \
  "Would ensure bundle id com.logseq.logseq.script-check" \
  env LOGSEQ_IOS_DRY_RUN=1 \
    APP_STORE_CONNECT_API_KEY_ID=fake-key-id \
    APP_STORE_CONNECT_ISSUER_ID=fake-issuer-id \
    APP_STORE_CONNECT_API_KEY_PATH="$fake_key" \
    "$repo_root/scripts/create-mobile-ios-profile.sh"

if [[ $failures -ne 0 ]]; then
  exit 1
fi
