#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

command -v adb >/dev/null 2>&1 || die "adb is not installed"

device=${ANDROID_SERIAL:-}
if [[ -z $device ]]; then
  device=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
fi
[[ -n $device ]] || die "no online Android emulator or device was found"

app_id=com.logseq.logseq
adb -s "$device" shell dumpsys gfxinfo "$app_id" reset >/dev/null
sleep 3

metrics=$(adb -s "$device" shell dumpsys gfxinfo "$app_id")
frames=$(sed -n 's/^Total frames rendered: \([0-9][0-9]*\).*/\1/p' <<<"$metrics" | head -1)
[[ -n $frames ]] || die "Android frame metrics were unavailable"

maximum_idle_frames=10
if (( frames > maximum_idle_frames )); then
  die "Android rendered $frames frames while the authentication screen was idle for 3 seconds (maximum $maximum_idle_frames)"
fi

echo "ok - Android authentication screen stays idle ($frames frames in 3 seconds)"
