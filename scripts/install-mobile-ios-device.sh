#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ios_device_config=${LOGSEQ_IOS_CONFIG:-$repo_root/.logseq-ios-device.env}
if [[ -f $ios_device_config ]]; then
  source "$ios_device_config"
fi
bundle_id=${LOGSEQ_IOS_BUNDLE_ID:-com.logseq.logseq}
device=${LOGSEQ_IOS_DEVICE:-iPhone}
launch_app=${LOGSEQ_IOS_LAUNCH:-1}
profile=${LOGSEQ_IOS_PROFILE:-}

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $bundle_id != "com.logseq.logseq" || ${LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE:-0} == 1 ]] \
  || die "refusing to install over the production Logseq bundle id; set LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE=1 to replace it"
[[ -n $profile ]] || die "set LOGSEQ_IOS_PROFILE to a development provisioning profile for $bundle_id"
[[ -f $profile ]] || die "provisioning profile was not found: $profile"

devices=$(xcrun devicectl list devices)
device_state=$(
  awk -v device="$device" '
    NR > 2 && ($1 == device || $3 == device) {
      print $4
      exit
    }
  ' <<<"$devices"
)
[[ -n $device_state ]] || die "target iOS device '$device' was not found
$devices"
[[ $device_state == "available" || $device_state == "connected" ]] || die "target iOS device '$device' is $device_state
$devices"

build_log=$(mktemp /tmp/logseq-ios-device-build.XXXXXX)
"$repo_root/scripts/build-mobile-ios-device.sh" | tee "$build_log"
app_dir=$(tail -n 1 "$build_log")

[[ -d $app_dir ]] || die "device build did not produce an app bundle: $app_dir"
actual_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_dir/Info.plist")
[[ $actual_bundle_id == "$bundle_id" ]] || die "built app bundle id is $actual_bundle_id, expected $bundle_id"
[[ $actual_bundle_id != "com.logseq.logseq" || ${LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE:-0} == 1 ]] \
  || die "refusing to install over the production Logseq bundle id"
[[ -f "$app_dir/embedded.mobileprovision" ]] || die "built app is missing embedded.mobileprovision"

echo "Installing $actual_bundle_id to device: $device"
xcrun devicectl device install app --device "$device" "$app_dir"

if [[ $launch_app == "1" ]]; then
  echo "Launching $actual_bundle_id on device: $device"
  xcrun devicectl device process launch --terminate-existing --device "$device" "$actual_bundle_id"
fi
