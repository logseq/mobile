#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
device=${1:?Pass the simulator UDID}
check_dir=$(mktemp -d)
app_id=com.logseq.logseq.SharedProviderCaptureCheck
trap 'xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true; xcrun simctl uninstall "$device" "$app_id" >/dev/null 2>&1 || true; rm -rf "$check_dir"' EXIT
app_dir="$check_dir/SharedProviderCaptureCheck.app"
mkdir -p "$app_dir"
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator \
  App/ShareExtension/ShareViewController.swift \
  App/ShareExtension/SharedProviderPolicy.swift \
  Sources/Logseq/SharedCapture.swift Tests/UI/shared-provider-capture.swift \
  -o "$app_dir/SharedProviderCaptureCheck"
cat > "$app_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$app_id</string>
<key>CFBundleExecutable</key><string>SharedProviderCaptureCheck</string>
<key>CFBundleName</key><string>SharedProviderCaptureCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - --entitlements App/ShareExtension/ShareExtension.entitlements "$app_dir" >/dev/null
xcrun simctl install "$device" "$app_dir"
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
echo "FAIL: share provider capture harness timed out"
exit 1
