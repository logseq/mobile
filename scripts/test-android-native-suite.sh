#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

adb=(adb -e)
app_id=com.logseq.logseq
report="$repo_root/android/app/build/native-tests/instrumentation.log"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/logseq-native-tests.XXXXXX")
remote_fixture="/data/local/tmp/${fixture##*/}.sqlite"
trap '"${adb[@]}" shell rm -f "$remote_fixture" || true; rm -rf "$fixture"' EXIT

./android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest
dune build shared/native/logseq_e2e_seed.exe
# Background sync must open a graph that already has today's journal.
cp android/app/src/androidTest/assets/feedback/graph.sqlite "$fixture/graph.sqlite"
_build/default/shared/native/logseq_e2e_seed.exe "$fixture/graph.sqlite" --composer

"${adb[@]}" install -r android/app/build/outputs/apk/debug/app-debug.apk
"${adb[@]}" install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
"${adb[@]}" push "$fixture/graph.sqlite" "$remote_fixture"

tests=(
  "$app_id.AndroidBackgroundSyncTest"
  "$app_id.AndroidEditorKeyboardTest"
  "$app_id.AndroidTaskDateSheetTest"
  "$app_id.AndroidDurableShareTest"
)
selector=$(IFS=,; echo "${tests[*]}")
mkdir -p "$(dirname "$report")"
"${adb[@]}" shell am instrument -w -r \
  -e class "$selector" -e backgroundGraphFixture "$remote_fixture" \
  "$app_id.test/androidx.test.runner.AndroidJUnitRunner" | tee "$report"

# Instrumentation can return exit status zero even with failing or skipped tests.
if ! grep -Eq '^OK \([1-9][0-9]* tests?\)' "$report" ||
   grep -Eq '^FAILURES!!!|^INSTRUMENTATION_STATUS_CODE: -[34][[:space:]]*$' "$report"; then
  echo "Android native tests failed or did not complete. See $report." >&2
  exit 1
fi
for test in "${tests[@]}"; do
  grep -Fxq "INSTRUMENTATION_STATUS: class=$test" "$report"
done
