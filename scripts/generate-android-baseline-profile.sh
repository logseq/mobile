#!/usr/bin/env bash
# Record android/app/src/main/baseline-prof.txt on a connected device.
#
# The device must be signed in with a graph open. Unlike Gradle's connected
# tasks, this script installs over the existing app and never uninstalls it,
# so the signed-in session and local graph survive.

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
device=${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}
[[ -n $device ]] || die "no online Android device was found"
adb=(adb -s "$device")

cd "$repo_root/android"
./gradlew :app:assembleBenchmark :baselineprofile:assembleBenchmark

app_apk=app/build/outputs/apk/benchmark/app-benchmark.apk
test_apk=baselineprofile/build/outputs/apk/benchmark/baselineprofile-benchmark.apk
"${adb[@]}" install -r "$app_apk"
"${adb[@]}" install -r -t "$test_apk"

output_dir=/sdcard/Android/media/com.logseq.logseq.baselineprofile
"${adb[@]}" shell rm -rf "$output_dir"
"${adb[@]}" shell am instrument -w \
  -e class com.logseq.logseq.baselineprofile.BaselineProfileGenerator \
  -e androidx.benchmark.enabledRules BaselineProfile \
  com.logseq.logseq.baselineprofile/androidx.test.runner.AndroidJUnitRunner | tee /dev/stderr | grep -q "^OK " \
  || die "baseline profile generation failed"

profile=$output_dir/BaselineProfileGenerator_journalHome-startup-prof.txt
"${adb[@]}" pull "$profile" app/src/main/baseline-prof.txt
"${adb[@]}" uninstall com.logseq.logseq.baselineprofile >/dev/null
echo "Wrote android/app/src/main/baseline-prof.txt ($(wc -l < app/src/main/baseline-prof.txt) rules)"
