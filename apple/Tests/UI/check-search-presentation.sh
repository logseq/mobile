#!/usr/bin/env bash
# Measure the production search presentation without XCTest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
device=${1:?Pass the simulator UDID}
build_dir=.build/arm64-apple-ios-simulator/debug
check_dir=$(mktemp -d)
app_id=com.logseq.logseq.SearchPresentationCheck
trap 'xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true; xcrun simctl uninstall "$device" "$app_id" >/dev/null 2>&1 || true; rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/SearchCheck.app"
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator -I "$build_dir/Modules" \
  Sources/Logseq/LGNavigationExtension.swift \
  Sources/Logseq/LGAdaptiveContentInsets.swift \
  Sources/Logseq/LGInteractionDiagnostics.swift \
  Sources/Logseq/LGLiquidGlassTweak.swift \
  Sources/Logseq/LogseqThemeSettings.swift \
  "$build_dir/Logseq.build/DerivedSources/resource_bundle_accessor.swift" \
  Tests/UI/search-presentation.swift "$build_dir"/LUIAppleBackend.build/*.o \
  -o "$check_dir/SearchCheck.app/SearchCheck"
cat > "$check_dir/SearchCheck.app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$app_id</string>
<key>CFBundleExecutable</key><string>SearchCheck</string>
<key>CFBundleName</key><string>SearchCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$check_dir/SearchCheck.app" >/dev/null
xcrun simctl install "$device" "$check_dir/SearchCheck.app"
xcrun simctl launch "$device" "$app_id"
data_dir=$(xcrun simctl get_app_container "$device" "$app_id" data)
for attempt in $(seq 1 100); do
  if [[ -f "$data_dir/Documents/result.txt" ]]; then
    cat "$data_dir/Documents/result.txt"
    ! rg -q FAIL "$data_dir/Documents/result.txt"
    exit $?
  fi
  sleep 0.25
done
echo "FAIL: search presentation harness timed out"
exit 1
