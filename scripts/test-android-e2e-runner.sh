#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$repo_root/scripts/test-android-e2e.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

list_output=$($runner --list) || die "Android E2E runner could not list modules"
grep -Fq "Modules: all signed-out smoke connect capture composer autocomplete outliner hierarchy audio navigation graphs settings flashcards search rich-content youtube node-tag page-actions shortcuts sharing editor-regressions sharing-image" <<<"$list_output" \
  || die "Android E2E runner did not list every module"
grep -Fq "tests/e2e/android-staging-connect.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the connection flow"
grep -Fq 'file: "android-graph-picker-sheet.yaml"' "$repo_root/tests/e2e/android-staging-connect.yaml" \
  || die "Android connection flow did not cover the Add sync graph sheet"
grep -Fq 'file: "android-graph-picker-settings.yaml"' "$repo_root/tests/e2e/android-staging-connect.yaml" \
  || die "Android connection flow did not cover graph-picker Settings"
grep -Fq 'file: "android-graph-picker-open.yaml"' "$repo_root/tests/e2e/android-staging-connect.yaml" \
  || die "Android connection flow did not verify graph download and open"
grep -Fq 'id: "button.composer.expand"' "$repo_root/tests/e2e/android-graph-picker-open.yaml" \
  || die "Android graph-picker open flow did not verify the downloaded graph"
grep -Fq "tests/e2e/android-signed-out.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the signed-out flow"
grep -Fq "tests/e2e/android-capture-search.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the capture flow"
grep -Fq 'id: "button.block-task-status"' "$repo_root/tests/e2e/android-capture-search.yaml" \
  || die "Android capture E2E does not preserve task status through search navigation"
grep -Fq "tests/e2e/android-composer-lifecycle.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the composer lifecycle flow"
grep -Fq "tests/e2e/android-outliner-autocomplete-completion.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the autocomplete flow"
grep -Fq "tests/e2e/android-outliner-interactions.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the outliner interaction flow"
grep -Fq 'Collapse Android E2E continuous first' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not cover collapsing a hierarchy"
grep -Fq 'Expand Android E2E continuous first' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not cover expanding a hierarchy"
grep -Fq "tests/e2e/android-audio-recording.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the audio recording flow"
grep -Fq 'toggle.audio.transcription' "$repo_root/tests/e2e/android-audio-recording.yaml" \
  || die "Android audio E2E does not cover the iOS transcription preference"
grep -Fq "tests/e2e/android-material-navigation.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the Material navigation flow"
grep -Fq 'id: "section.sidebar.favorites"' "$repo_root/tests/e2e/android-material-navigation.yaml" \
  || die "Material navigation does not cover sidebar favorites"
grep -Fq 'id: "pane.selected-page"' "$repo_root/tests/e2e/android-material-navigation.yaml" \
  || die "Material navigation does not cover the selected-page pane"
grep -Fq 'id: "button.journal.e2e10000-0000-4000-8000-000000000001"' "$repo_root/tests/e2e/android-material-navigation.yaml" \
  || die "Material navigation does not cover journal header navigation"
grep -Fq 'id: "journal.divider"' "$repo_root/tests/e2e/android-material-navigation.yaml" \
  || die "Material navigation does not cover journal day separation"
grep -Fq 'elif [[ $flow == "$navigation_flow" ]]; then' "$runner" \
  || die "Android E2E runner does not seed the navigation fixture"
grep -Fq "tests/e2e/android-graphs.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the graph presentation flow"
grep -Fq 'button.graphs.refresh' "$repo_root/tests/e2e/android-graphs.yaml" \
  || die "Android graph E2E does not cover refresh"
grep -Fq 'button.graph-delete.confirm' "$repo_root/tests/e2e/android-graphs.yaml" \
  || die "Android graph E2E does not cover delete confirmation"
grep -Fq "tests/e2e/android-settings.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the settings parity flow"
grep -Fq 'android-settings-material-icons' "$repo_root/tests/e2e/android-settings.yaml" \
  || die "Android settings E2E does not retain a Material icon screenshot"
grep -Fq 'android-settings-dark-theme' "$repo_root/tests/e2e/android-settings.yaml" \
  || die "Android settings E2E does not verify the applied Material theme"
grep -Fq 'id: "picker.settings.appearance"' "$repo_root/tests/e2e/android-settings.yaml" \
  || die "Android settings E2E does not operate the Theme select"
grep -Fq 'id: "field.base-url"' "$repo_root/tests/e2e/android-settings.yaml" \
  || die "Android settings E2E does not cover the server URL form"
grep -Fq 'id: "switch.settings.spell-check"' "$repo_root/tests/e2e/android-settings.yaml" \
  || die "Android settings E2E does not cover native editor switches"
grep -Fq 'id: "link.settings.community.github"' "$repo_root/tests/e2e/android-settings.yaml" \
  || die "Android settings E2E does not cover community links"
grep -Fq "tests/e2e/android-flashcards-regression.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the flashcards parity flow"
grep -Fq "tests/e2e/android-search-navigation.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the search and node parity flow"
grep -Fq "tests/e2e/android-rich-block-rendering.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the rich content parity flow"
grep -Fq "tests/e2e/android-youtube-playback.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the YouTube playback flow"
grep -Fq "tests/e2e/android-node-tag-navigation.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the node and tag parity flow"
grep -Fq "tests/e2e/android-page-actions.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the page actions parity flow"
grep -Fq "tests/e2e/android-shortcut-deep-links.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the shortcut deep-link parity flow"
grep -Fq "tests/e2e/android-share-capture.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the inbound share parity flow"
grep -Fq "tests/e2e/android-rapid-enter-delete-regression.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the rapid editor regression flow"
grep -Fq 'Android keyboard remains active' "$repo_root/tests/e2e/android-rapid-enter-delete-regression.yaml" \
  || die "Android rapid editor regression did not verify continued input"
grep -Fq "tests/e2e/android-outliner-hierarchy-navigation.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list hierarchy navigation parity"
grep -Fq "tests/e2e/android-share-image.yaml" <<<"$list_output" \
  || die "Android E2E runner did not list the inbound image-share parity flow"
grep -Fq 'button.outliner.selection.indent' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not cover selection indent"
grep -Fq 'button.outliner.selection.outdent' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not cover selection outdent"
grep -Fq 'toolbars/editor-trailing' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not retain editor toolbar visual evidence"
grep -Fq 'toolbars/selection-trailing' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not retain selection toolbar visual evidence"
grep -Fq 'id: "button.outliner-delete.confirm"' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not confirm block deletion"
grep -Fq 'assertNotVisible: "Android E2E continuous second"' "$repo_root/tests/e2e/android-outliner-interactions.yaml" \
  || die "Android outliner E2E does not verify confirmed block deletion"
grep -Fq 'assertVisible: "Card"' "$repo_root/tests/e2e/android-outliner-autocomplete-completion.yaml" \
  || die "Android autocomplete E2E does not cover the built-in Card tag"
grep -Fq 'openLink: "logseq://capture"' "$repo_root/tests/e2e/android-shortcut-deep-links.yaml" \
  || die "Android shortcut E2E does not cover Capture"
grep -Fq 'openLink: "logseq://journal"' "$repo_root/tests/e2e/android-shortcut-deep-links.yaml" \
  || die "Android shortcut E2E does not cover Journal"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/logseq-android-e2e.XXXXXX")
invalid_output="$temporary_directory/invalid-output"
missing_output="$temporary_directory/missing-output"
mock_bin="$temporary_directory/bin"
custom_flow="$temporary_directory/custom-flow.yaml"
maestro_args="$temporary_directory/maestro-args"
adb_args="$temporary_directory/adb-args"
gradle_args="$temporary_directory/gradle-args"
mkdir -p "$mock_bin"
trap 'rm -rf "$temporary_directory"' EXIT

if LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" unsupported >"$invalid_output" 2>&1; then
  die "Android E2E runner accepted an unknown module"
fi
grep -Fq "unknown Android E2E module or flow: unsupported" "$invalid_output" \
  || die "Android E2E runner did not explain the unknown module"

if env -u LOGSEQ_E2E_USERNAME \
  -u LOGSEQ_E2E_PASSWORD \
  -u LOGSEQ_E2E_BASE_URL \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" connect >"$missing_output" 2>&1; then
  die "Android E2E runner accepted missing connection parameters"
fi
grep -Fq "LOGSEQ_E2E_USERNAME is required" "$missing_output" \
  || die "Android E2E runner did not explain the missing connection parameter"

cat >"$mock_bin/adb" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${LOGSEQ_ADB_ARGS:-} ]]; then
  printf '%s\n' "$*" >>"$LOGSEQ_ADB_ARGS"
fi
case "$*" in
  *"shell am start -W -S"*)
    printf '%s\n' 'Status: ok' 'LaunchState: COLD' 'TotalTime: 842' 'Complete'
    ;;
  *"logcat -d -v brief"*)
    printf '%s\n' \
      'I/System.out: LOGSEQ_LAUNCH_METRIC authentication_published_ms=402.000' \
      'I/System.out: LOGSEQ_LAUNCH_METRIC first_ui_rendered_ms=404.000'
    ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf \"%%s\\n\" \"$@\" >\"$LOGSEQ_MAESTRO_ARGS\"\n' >"$mock_bin/maestro"
cat >"$mock_bin/gradle" <<'GMOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$LOGSEQ_GRADLE_ARGS"
GMOCK
chmod +x "$mock_bin/adb" "$mock_bin/maestro" "$mock_bin/gradle"
printf 'appId: com.logseq.app\n---\n- launchApp\n' >"$custom_flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" "$custom_flow" >/dev/null
[[ $(tail -n 1 "$maestro_args") == "$custom_flow" ]] \
  || die "Android E2E runner changed an absolute custom flow path"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_ANDROID_GRADLE=gradle \
  LOGSEQ_GRADLE_ARGS="$gradle_args" \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_VISUAL_GATES=1 \
  "$runner" signed-out >/dev/null
[[ $(<"$gradle_args") == "-p $repo_root/android :app:assembleProfile" ]] \
  || die "Android E2E runner did not build the profile APK"

: >"$adb_args"
PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_ADB_ARGS="$adb_args" \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" sharing >/dev/null
grep -Fq 'android.intent.action.SEND' "$adb_args" \
  || die "Android E2E runner did not inject a real ACTION_SEND intent"
grep -Fq 'android.intent.extra.TITLE Android\ share' "$adb_args" \
  || die "Android E2E runner did not preserve the spaced share title"

: >"$adb_args"
PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_ADB_ARGS="$adb_args" \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" sharing-image >/dev/null
grep -Fq 'image/png' "$adb_args" \
  || die "Android E2E runner did not inject an image ACTION_SEND intent"
grep -Fq 'android.intent.extra.STREAM' "$adb_args" \
  || die "Android image-share E2E omitted EXTRA_STREAM"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_VISUAL_GATES=1 \
  "$runner" signed-out >/dev/null

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_E2E_USERNAME=test-user \
  LOGSEQ_E2E_PASSWORD=test-password \
  LOGSEQ_E2E_BASE_URL=https://api.example \
  "$runner" connect >/dev/null
expected_connect_args=$(printf '%s\n' \
  --device test-device test \
  -e USERNAME=test-user \
  -e PASSWORD=test-password \
  "$repo_root/tests/e2e/android-staging-connect.yaml")
[[ $(<"$maestro_args") == "$expected_connect_args" ]] \
  || die "Android E2E runner passed Maestro environment options outside the test command"

: >"$adb_args"
PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_ADB_ARGS="$adb_args" \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_E2E_USERNAME=test-user \
  LOGSEQ_E2E_PASSWORD=test-password \
  LOGSEQ_E2E_BASE_URL=http://127.0.0.1:8787 \
  LOGSEQ_ANDROID_E2E_SKIP_DB_SYNC_WAIT=1 \
  "$runner" connect >/dev/null
grep -Fxq -- '-s test-device reverse tcp:8787 tcp:8787' "$adb_args" \
  || die "Android E2E runner did not expose the host-local backend to the device"
grep -Eq 'run-as com\.logseq\.app cp .* shared_prefs/logseq\.xml$' "$adb_args" \
  || die "Android E2E server override did not use the app's SharedPreferences file"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" navigation >/dev/null
expected_navigation_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-material-navigation.yaml")
[[ $(<"$maestro_args") == "$expected_navigation_args" ]] \
  || die "Android E2E runner did not preserve the Material navigation flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" graphs >/dev/null
expected_graphs_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-graphs.yaml")
[[ $(<"$maestro_args") == "$expected_graphs_args" ]] \
  || die "Android E2E runner did not preserve the graph presentation flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" settings >/dev/null
expected_settings_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-settings.yaml")
[[ $(<"$maestro_args") == "$expected_settings_args" ]] \
  || die "Android E2E runner did not preserve the settings parity flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" flashcards >/dev/null
expected_flashcards_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-flashcards-regression.yaml")
[[ $(<"$maestro_args") == "$expected_flashcards_args" ]] \
  || die "Android E2E runner did not preserve the flashcards parity flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" search >/dev/null
expected_search_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-search-navigation.yaml")
[[ $(<"$maestro_args") == "$expected_search_args" ]] \
  || die "Android E2E runner did not preserve the search and node parity flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" outliner >/dev/null
expected_outliner_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-outliner-interactions.yaml")
[[ $(<"$maestro_args") == "$expected_outliner_args" ]] \
  || die "Android E2E runner did not preserve the outliner interaction flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  "$runner" composer >/dev/null
expected_composer_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-composer-lifecycle.yaml")
[[ $(<"$maestro_args") == "$expected_composer_args" ]] \
  || die "Android E2E runner did not preserve the composer lifecycle flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" audio >/dev/null
expected_audio_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-audio-recording.yaml")
[[ $(<"$maestro_args") == "$expected_audio_args" ]] \
  || die "Android E2E runner did not preserve the audio recording flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" rich-content >/dev/null
expected_rich_content_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-rich-block-rendering.yaml")
[[ $(<"$maestro_args") == "$expected_rich_content_args" ]] \
  || die "Android E2E runner did not preserve the rich content parity flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" youtube >/dev/null
expected_youtube_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-youtube-playback.yaml")
[[ $(<"$maestro_args") == "$expected_youtube_args" ]] \
  || die "Android E2E runner did not preserve the YouTube playback flow"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" node-tag >/dev/null
expected_node_tag_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-node-tag-navigation.yaml")
[[ $(<"$maestro_args") == "$expected_node_tag_args" ]] \
  || die "Android E2E runner did not preserve the node and tag parity flow"

: >"$adb_args"
cat >"$mock_bin/adb" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${LOGSEQ_ADB_ARGS:-} ]]; then
  printf '%s\n' "$*" >>"$LOGSEQ_ADB_ARGS"
fi
case "$*" in
  *"exec-out uiautomator dump"*)
    printf '%s\n' \
      '<hierarchy><node text="Pixel Launcher isn'"'"'t responding" bounds="[28,979][1052,1485]"/><node text="Close app" bounds="[136,879][314,945]"/><node text="Wait" bounds="[400,879][578,945]"/></hierarchy>'
    ;;
esac
EOF
printf '#!/usr/bin/env bash\nsleep 1\nprintf "%%s\\n" "$@" >"$LOGSEQ_MAESTRO_ARGS"\n' >"$mock_bin/maestro"
chmod +x "$mock_bin/adb" "$mock_bin/maestro"
PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_ADB_ARGS="$adb_args" \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" settings >/dev/null
grep -Fq -- '-s test-device shell input tap 225 912' "$adb_args" \
  || die "Android E2E runner's ANR watchdog did not tap the dialog's Close app button"

PATH="$mock_bin:$PATH" \
  ANDROID_SERIAL=test-device \
  LOGSEQ_MAESTRO_ARGS="$maestro_args" \
  LOGSEQ_ANDROID_E2E_SKIP_BUILD=1 \
  LOGSEQ_ANDROID_E2E_SKIP_INSTALL=1 \
  LOGSEQ_ANDROID_E2E_SKIP_SEED=1 \
  "$runner" page-actions >/dev/null
expected_page_actions_args=$(printf '%s\n' \
  --device test-device test \
  "$repo_root/tests/e2e/android-page-actions.yaml")
[[ $(<"$maestro_args") == "$expected_page_actions_args" ]] \
  || die "Android E2E runner did not preserve the page actions parity flow"

echo "Android E2E runner tests passed"
