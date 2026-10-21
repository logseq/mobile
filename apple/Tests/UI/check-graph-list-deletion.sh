#!/usr/bin/env bash
# Verify production graph-list deletion without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
device=${1:?Pass the simulator UDID}
build_dir=${LUI_GRAPH_LIST_BUILD_DIR:-.build/arm64-apple-ios-simulator/debug}
check_dir=$(mktemp -d)
app_id=com.logseq.logseq.GraphListDeletionCheck
trap 'xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true; xcrun simctl uninstall "$device" "$app_id" >/dev/null 2>&1 || true; rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/GraphListDeletionCheck.app"
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator -I "$build_dir/Modules" \
  Tests/UI/graph-list-deletion.swift "$build_dir"/LUIAppleBackend.build/*.o \
  -o "$check_dir/GraphListDeletionCheck.app/GraphListDeletionCheck"
cat > "$check_dir/GraphListDeletionCheck.app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$app_id</string>
<key>CFBundleExecutable</key><string>GraphListDeletionCheck</string>
<key>CFBundleName</key><string>GraphListDeletionCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
cp Tests/UI/graph-list-deletion-patches.json "$check_dir/GraphListDeletionCheck.app/"
codesign --force --sign - "$check_dir/GraphListDeletionCheck.app" >/dev/null
xcrun simctl install "$device" "$check_dir/GraphListDeletionCheck.app"
xcrun simctl launch "$device" "$app_id"
data_dir=$(xcrun simctl get_app_container "$device" "$app_id" data)
for attempt in $(seq 1 160); do
  if [[ -f "$data_dir/Documents/result.txt" ]]; then
    cat "$data_dir/Documents/result.txt"
    ! rg -q FAIL "$data_dir/Documents/result.txt"
    exit $?
  fi
  sleep 0.25
done
echo "FAIL: graph-list deletion harness timed out"
exit 1
