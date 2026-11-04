#!/usr/bin/env bash

set -euo pipefail

app_id=com.logseq.logseq
activity="$app_id/com.logseq.logseq.MainActivity"
device=${ANDROID_SERIAL:-}
total_budget_ms=${LOGSEQ_ANDROID_TOTAL_TIME_BUDGET_MS:-2000}
first_ui_budget_ms=${LOGSEQ_ANDROID_FIRST_UI_BUDGET_MS:-1200}
authentication_budget_ms=${LOGSEQ_ANDROID_AUTHENTICATION_BUDGET_MS:-1500}

die() {
  echo "error: $*" >&2
  exit 1
}

command -v adb >/dev/null 2>&1 || die "adb is not installed"
if [[ -z $device ]]; then
  device=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
fi
[[ -n $device ]] || die "no online Android emulator or device was found"

adb -s "$device" logcat -c
launch_output=$(adb -s "$device" shell am start -W -S -n "$activity")
total_time=$(sed -n 's/^TotalTime: *\([0-9][0-9]*\)$/\1/p' <<<"$launch_output" | tail -1)
[[ -n $total_time ]] || die "Android cold launch did not report TotalTime
$launch_output"

launch_log=""
for _ in {1..60}; do
  launch_log=$(adb -s "$device" logcat -d -v brief)
  if grep -q 'LOGSEQ_LAUNCH_METRIC first_ui_rendered_ms=' <<<"$launch_log" \
    && grep -q 'LOGSEQ_LAUNCH_METRIC authentication_published_ms=' <<<"$launch_log"; then
    break
  fi
  sleep 0.05
done

first_ui=$(sed -n \
  's/.*LOGSEQ_LAUNCH_METRIC first_ui_rendered_ms=\([0-9.][0-9.]*\).*/\1/p' \
  <<<"$launch_log" | tail -1)
authentication=$(sed -n \
  's/.*LOGSEQ_LAUNCH_METRIC authentication_published_ms=\([0-9.][0-9.]*\).*/\1/p' \
  <<<"$launch_log" | tail -1)
[[ -n $first_ui ]] || die "Android launch did not emit first_ui_rendered_ms"
[[ -n $authentication ]] || die "Android launch did not emit authentication_published_ms"

awk -v actual="$total_time" -v budget="$total_budget_ms" 'BEGIN {
  if (actual > budget) {
    printf "Android cold launch exceeded budget: %.3fms > %.3fms\n", actual, budget > "/dev/stderr"
    exit 1
  }
}'
awk -v actual="$first_ui" -v budget="$first_ui_budget_ms" 'BEGIN {
  if (actual > budget) {
    printf "Android first UI exceeded budget: %.3fms > %.3fms\n", actual, budget > "/dev/stderr"
    exit 1
  }
}'
awk -v actual="$authentication" -v budget="$authentication_budget_ms" 'BEGIN {
  if (actual > budget) {
    printf "Android authentication UI exceeded budget: %.3fms > %.3fms\n", actual, budget > "/dev/stderr"
    exit 1
  }
}'

printf 'Android cold launch: %sms; first UI: %sms; authentication UI: %sms\n' \
  "$total_time" "$first_ui" "$authentication"
