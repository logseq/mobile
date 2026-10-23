#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_id=com.logseq.app
signed_out_flow=tests/e2e/android-signed-out.yaml
local_setup_flow=tests/e2e/android-local-graph-setup.yaml
connect_flow=tests/e2e/android-staging-connect.yaml
capture_flow=tests/e2e/android-capture-search.yaml
composer_flow=tests/e2e/android-composer-lifecycle.yaml
autocomplete_flow=tests/e2e/android-outliner-autocomplete-completion.yaml
outliner_flow=tests/e2e/android-outliner-interactions.yaml
hierarchy_flow=tests/e2e/android-outliner-hierarchy-navigation.yaml
audio_flow=tests/e2e/android-audio-recording.yaml
navigation_flow=tests/e2e/android-material-navigation.yaml
graphs_flow=tests/e2e/android-graphs.yaml
settings_flow=tests/e2e/android-settings.yaml
flashcards_flow=tests/e2e/android-flashcards-regression.yaml
search_flow=tests/e2e/android-search-navigation.yaml
rich_content_flow=tests/e2e/android-rich-block-rendering.yaml
youtube_flow=tests/e2e/android-youtube-playback.yaml
node_tag_flow=tests/e2e/android-node-tag-navigation.yaml
page_actions_flow=tests/e2e/android-page-actions.yaml
shortcuts_flow=tests/e2e/android-shortcut-deep-links.yaml
sharing_flow=tests/e2e/android-share-capture.yaml
editor_regressions_flow=tests/e2e/android-rapid-enter-delete-regression.yaml
sharing_image_flow=tests/e2e/android-share-image.yaml

die() {
  echo "error: $*" >&2
  exit 1
}

selector=${1:-${LOGSEQ_ANDROID_E2E_MODULE:-all}}
case $selector in
  all)
    flows=(
      "$signed_out_flow"
      "$connect_flow"
      "$capture_flow"
      "$composer_flow"
      "$autocomplete_flow"
      "$outliner_flow"
      "$hierarchy_flow"
      "$audio_flow"
      "$navigation_flow"
      "$graphs_flow"
      "$settings_flow"
      "$flashcards_flow"
      "$search_flow"
      "$rich_content_flow"
      "$youtube_flow"
      "$node_tag_flow"
      "$page_actions_flow"
      "$shortcuts_flow"
      "$sharing_flow"
      "$editor_regressions_flow"
      "$sharing_image_flow"
    )
    needs_connection=1
    needs_clear_state=1
    needs_primary_button=1
    ;;
  signed-out)
    flows=("$signed_out_flow")
    needs_connection=0
    needs_clear_state=1
    needs_primary_button=1
    ;;
  smoke)
    # Fresh-install smoke: bypass hosted sign-in, create a local graph, then
    # run the capture assertions. Works without backend credentials.
    flows=("$signed_out_flow" "$local_setup_flow" "$capture_flow")
    needs_connection=0
    needs_clear_state=1
    needs_primary_button=0
    ;;
  connect)
    flows=("$connect_flow")
    needs_connection=1
    needs_clear_state=1
    needs_primary_button=0
    ;;
  capture)
    flows=("$capture_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  composer)
    flows=("$composer_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  autocomplete)
    flows=("$autocomplete_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  outliner)
    flows=("$outliner_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  hierarchy)
    flows=("$hierarchy_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  audio)
    flows=("$audio_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  navigation)
    flows=("$navigation_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  graphs)
    flows=("$graphs_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  settings)
    flows=("$settings_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  flashcards)
    flows=("$flashcards_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  search)
    flows=("$search_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  rich-content)
    flows=("$rich_content_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  youtube)
    flows=("$youtube_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  node-tag)
    flows=("$node_tag_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  page-actions)
    flows=("$page_actions_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  shortcuts)
    flows=("$shortcuts_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  sharing)
    flows=("$sharing_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  editor-regressions)
    flows=("$editor_regressions_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  sharing-image)
    flows=("$sharing_image_flow")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  --list)
    echo "Modules: all signed-out smoke connect capture composer autocomplete outliner hierarchy audio navigation graphs settings flashcards search rich-content youtube node-tag page-actions shortcuts sharing editor-regressions sharing-image"
    printf '%s\n' \
      "$signed_out_flow" \
      "$connect_flow" \
      "$capture_flow" \
      "$composer_flow" \
      "$autocomplete_flow" \
      "$outliner_flow" \
      "$hierarchy_flow" \
      "$audio_flow" \
      "$navigation_flow" \
      "$graphs_flow" \
      "$settings_flow" \
      "$flashcards_flow" \
      "$search_flow" \
      "$rich_content_flow" \
      "$youtube_flow" \
      "$node_tag_flow" \
      "$page_actions_flow" \
      "$shortcuts_flow" \
      "$sharing_flow" \
      "$editor_regressions_flow" \
      "$sharing_image_flow"
    exit 0
    ;;
  *.yaml)
    if [[ $selector = /* ]]; then
      flow_path=$selector
    else
      flow_path="$repo_root/$selector"
    fi
    [[ -f $flow_path ]] || die "Android E2E flow not found: $selector"
    flows=("$selector")
    needs_connection=0
    needs_clear_state=0
    needs_primary_button=0
    ;;
  *)
    die "unknown Android E2E module or flow: $selector"
    ;;
esac

if (( needs_connection )); then
  : "${LOGSEQ_E2E_USERNAME:?error: LOGSEQ_E2E_USERNAME is required}"
  : "${LOGSEQ_E2E_PASSWORD:?error: LOGSEQ_E2E_PASSWORD is required}"
  : "${LOGSEQ_E2E_BASE_URL:?error: LOGSEQ_E2E_BASE_URL is required}"
fi
# Modules that still sign in through the in-app Cognito form (e.g. smoke's
# local server setup) use the shared dev-account defaults.
LOGSEQ_E2E_USERNAME=${LOGSEQ_E2E_USERNAME:-e2etest}
LOGSEQ_E2E_PASSWORD=${LOGSEQ_E2E_PASSWORD:-Logseq-e2e}

command -v adb >/dev/null 2>&1 || die "adb is not installed"
command -v maestro >/dev/null 2>&1 || die "Maestro CLI is not installed"
[[ -x $repo_root/android/gradlew ]] || die "android/gradlew is missing"

temporary_files=()
anr_watchdog_pid=""
cleanup() {
  if [[ -n $anr_watchdog_pid ]]; then
    kill "$anr_watchdog_pid" 2>/dev/null || true
  fi
  if (( ${#temporary_files[@]} > 0 )); then
    rm -f "${temporary_files[@]}"
  fi
}
trap cleanup EXIT

# A system ANR dialog ("<app> isn't responding", e.g. Pixel Launcher on a
# loaded emulator) occludes the whole a11y tree — Maestro can't see the app
# behind it and every assertion times out. Tap its "Wait" button so a
# system-level hiccup can't fail a flow whose app is healthy.
start_anr_watchdog() {
  (
    while :; do
      xml=$(adb -s "$device" exec-out uiautomator dump /dev/tty 2>/dev/null || true)
      if printf '%s' "$xml" | grep -q "isn't responding"; then
        anr_app=$(printf '%s' "$xml" | tr '>' '\n' \
          | sed -n "s/.*text=\"\(.*\) isn't responding\".*/\1/p" | head -1)
        # "Wait" only postpones the dialog — a genuinely hung app process
        # (Pixel Launcher on a loaded emulator) re-ANRs forever, so
        # "Close app" force-stops it and Android restarts it fresh. But
        # for system_server/System UI, "Close app" kills the runtime and
        # soft-reboots the device, dropping every adb transport — always
        # pick "Wait" there and let the transient stall recover.
        case "$anr_app" in
          *system_server*|*"System UI"*|*settings*)
            close_bounds=$(printf '%s' "$xml" | tr '>' '\n' \
              | sed -n 's/.*text="Wait"[^>]*bounds="\(\[[0-9,]*\]\[[0-9,]*\]\)".*/\1/p' | head -1)
            action="Wait" ;;
          *)
            close_bounds=$(printf '%s' "$xml" | tr '>' '\n' \
              | sed -n 's/.*text="Close app"[^>]*bounds="\(\[[0-9,]*\]\[[0-9,]*\]\)".*/\1/p' | head -1)
            action="Close app" ;;
        esac
        if [[ -z $close_bounds ]]; then
          close_bounds=$(printf '%s' "$xml" | tr '>' '\n' \
            | sed -n 's/.*text="Wait"[^>]*bounds="\(\[[0-9,]*\]\[[0-9,]*\]\)".*/\1/p' | head -1)
          action="Wait"
        fi
        if [[ $close_bounds =~ \[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\] ]]; then
          x=$(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 ))
          y=$(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 ))
          echo "[anr-watchdog] dismissing '$anr_app' ANR dialog ($action at $x,$y)" >&2
          adb -s "$device" shell input tap "$x" "$y" >/dev/null 2>&1 || true
        fi
      fi
      # Every 3s turned out to hammer the a11y framework hard enough to
      # starve Maestro's own UiAutomation binding on loaded emulators;
      # 10s still catches ANR dialogs well inside assert timeouts.
      sleep 10
    done
  ) &
  anr_watchdog_pid=$!
}

device=${ANDROID_SERIAL:-}
if [[ -z $device ]]; then
  device=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
fi
[[ -n $device ]] || die "no online Android emulator or device was found"

# Suppress ANR dialogs for background processes up front; the watchdog below
# still closes foreground ANRs (e.g. Pixel Launcher) by force-stopping them.
adb -s "$device" shell settings put global anr_show_background 0 >/dev/null 2>&1 || true
if [[ ${LOGSEQ_ANDROID_E2E_SKIP_ANR_WATCHDOG:-0} != 1 ]]; then
  start_anr_watchdog
fi

if [[ -n ${LOGSEQ_E2E_BASE_URL:-} ]] \
  && [[ $LOGSEQ_E2E_BASE_URL =~ ^(http|https)://(127\.0\.0\.1|localhost)(:([0-9]+))?([/?#]|$) ]]; then
  local_backend_port=${BASH_REMATCH[4]:-}
  if [[ -z $local_backend_port ]]; then
    if [[ ${BASH_REMATCH[1]} == https ]]; then
      local_backend_port=443
    else
      local_backend_port=80
    fi
  fi
  adb -s "$device" reverse "tcp:$local_backend_port" "tcp:$local_backend_port"
fi

if [[ ${LOGSEQ_ANDROID_E2E_SKIP_BUILD:-0} != 1 ]]; then
  gradle=${LOGSEQ_ANDROID_GRADLE:-"$repo_root/android/gradlew"}
  ANDROID_SERIAL=$device "$gradle" -p "$repo_root/android" :app:assembleProfile
fi

if [[ ${LOGSEQ_ANDROID_E2E_SKIP_INSTALL:-0} != 1 ]]; then
  apk="$repo_root/android/app/build/outputs/apk/profile/app-profile.apk"
  [[ -f $apk ]] || die "Android profile APK was not produced at $apk"
  adb -s "$device" install -r "$apk" >/dev/null
fi

if (( needs_clear_state )) && [[ ${LOGSEQ_ANDROID_E2E_CLEAR_STATE:-1} == 1 ]]; then
  adb -s "$device" shell pm clear "$app_id" >/dev/null
fi

if (( needs_primary_button )); then
  ANDROID_SERIAL=$device "$repo_root/scripts/test-android-launch-performance.sh"
fi

if (( needs_connection )) && [[ ${LOGSEQ_ANDROID_E2E_CLEAR_BROWSER_STATE:-1} == 1 ]]; then
  browser_package=${LOGSEQ_ANDROID_E2E_BROWSER_PACKAGE:-com.android.chrome}
  if adb -s "$device" shell pm path "$browser_package" >/dev/null 2>&1; then
    adb -s "$device" shell pm clear "$browser_package" >/dev/null
  fi
fi

if [[ -n ${LOGSEQ_E2E_BASE_URL:-} ]]; then
  [[ $LOGSEQ_E2E_BASE_URL != *['<>&"']* ]] \
    || die "LOGSEQ_E2E_BASE_URL contains characters that are unsafe in Android preferences"
  preferences_file=$(mktemp "${TMPDIR:-/tmp}/logseq-android-defaults.xml.XXXXXX")
  temporary_files+=("$preferences_file")
  remote_preferences="/data/local/tmp/logseq-android-defaults-$$.xml"
  printf '%s\n' \
    "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" \
    '<map>' \
    '    <string name="logseq.appearance">system</string>' \
    '    <string name="logseq.language">system</string>' \
    "    <string name=\"logseq.baseURL\">$LOGSEQ_E2E_BASE_URL</string>" \
    '</map>' >"$preferences_file"
  adb -s "$device" push "$preferences_file" "$remote_preferences" >/dev/null
  adb -s "$device" shell run-as "$app_id" mkdir -p shared_prefs
  adb -s "$device" shell run-as "$app_id" cp "$remote_preferences" shared_prefs/logseq.xml
  adb -s "$device" shell rm -f "$remote_preferences"
fi

seed_android_fixture() {
  local seed_mode=${1:-}
  command -v opam >/dev/null 2>&1 || die "opam is required to seed the Android fixture"
  local selected_graph_id=""
  local graph_database=""
  local checkpoint=""
  local graph_ready=0
  for _ in {1..120}; do
    selected_graph_id=$(adb -s "$device" shell run-as "$app_id" \
      cat shared_prefs/logseq.xml 2>/dev/null \
      | sed -n 's|.*<string name="logseq.selectedGraphId">\([^<]*\)</string>.*|\1|p' \
      | tr -d '\r' | head -1)
    if [[ $selected_graph_id =~ ^[A-Za-z0-9._-]+$ ]]; then
      local graph_directory
      graph_directory=$(python3 "$repo_root/scripts/android-selected-graph.py" \
        --device "$device" --app "$app_id" --graph-id "$selected_graph_id" 2>/dev/null || true)
      if [[ -n $graph_directory ]]; then
        graph_database="$graph_directory/graph.sqlite"
        checkpoint="$graph_directory/sync.checkpoint"
      fi
    fi
    if [[ -n $graph_database ]] \
      && adb -s "$device" shell run-as "$app_id" test -f "$graph_database" \
      && adb -s "$device" shell run-as "$app_id" test -f "$checkpoint"; then
      graph_ready=1
      break
    fi
    sleep 0.5
  done
  (( graph_ready )) \
    || die "timed out waiting for the selected Android graph database"

  adb -s "$device" shell am force-stop "$app_id"
  local local_database
  local_database=$(mktemp "${TMPDIR:-/tmp}/logseq-android-graph.XXXXXX")
  temporary_files+=("$local_database")
  adb -s "$device" exec-out run-as "$app_id" cat "$graph_database" >"$local_database"
  local dune_seed=()
  if command -v dune >/dev/null 2>&1; then
    dune_seed=(dune exec)
  else
    dune_seed=(opam exec --switch=5.5.0 -- dune exec)
  fi
  if [[ -n $seed_mode ]]; then
    "${dune_seed[@]}" shared/native/logseq_e2e_seed.exe -- "$local_database" "$seed_mode"
  else
    "${dune_seed[@]}" shared/native/logseq_e2e_seed.exe -- "$local_database"
  fi

  local remote_database="/data/local/tmp/logseq-android-graph-$$.sqlite"
  adb -s "$device" push "$local_database" "$remote_database" >/dev/null
  adb -s "$device" shell run-as "$app_id" \
    rm -f "${graph_database}-wal" "${graph_database}-shm"
  adb -s "$device" shell run-as "$app_id" cp "$remote_database" "$graph_database"
  adb -s "$device" shell rm -f "$remote_database"
}

if [[ -n ${LOGSEQ_E2E_BASE_URL:-} ]] \
  && [[ ${LOGSEQ_ANDROID_E2E_SKIP_DB_SYNC_WAIT:-0} != 1 ]] \
  && [[ $LOGSEQ_E2E_BASE_URL =~ ^(http|https)://(127\.0\.0\.1|localhost)(:([0-9]+))?([/?#]|$) ]]; then
  # CI builds db-sync in a background process; flows must not start before
  # it binds the port (a bound port returns any HTTP response, incl. 401/404).
  for attempt in $(seq 1 180); do
    if curl -s -o /dev/null "${LOGSEQ_E2E_BASE_URL}/"; then
      break
    fi
    if (( attempt == 180 )); then
      die "db-sync server did not come up at $LOGSEQ_E2E_BASE_URL"
    fi
    sleep 2
  done
fi

recover_device() {
  # Retrying a flow against a dead adb server, a flapped transport
  # (get-state answers but the adbd channel is closed), or a crashed
  # emulator fails identically — recover connectivity before the next
  # attempt. `adb shell echo ok` proves the channel end-to-end; get-state
  # alone only proves a stale transport entry. Pass "force" to skip the
  # connectivity ladder and relaunch the emulator directly — used when the
  # adb channel is fine but the Maestro driver itself is wedged.
  local force_relaunch=0
  [[ ${1:-} == force ]] && force_relaunch=1
  local device_ok=0
  if (( force_relaunch )); then
    :
  elif timeout 15 adb -s "$device" shell 'echo ok' 2>/dev/null | grep -q ok; then
    device_ok=1
  else
    echo "[android-e2e] device $device channel dead; reconnecting adb" >&2
    adb -s "$device" reconnect >/dev/null 2>&1 || true
    sleep 2
    if timeout 15 adb -s "$device" shell 'echo ok' 2>/dev/null | grep -q ok; then
      device_ok=1
    else
      echo "[android-e2e] restarting adb server" >&2
      adb kill-server >/dev/null 2>&1 || true
      sleep 1
      adb start-server >/dev/null 2>&1 || true
      timeout 60 adb -s "$device" wait-for-device 2>/dev/null || true
      if timeout 15 adb -s "$device" shell 'echo ok' 2>/dev/null | grep -q ok; then
        device_ok=1
      fi
    fi
  fi
  if (( device_ok )); then
    # adb reverse rules die with transport flaps even when the device
    # itself stayed up — re-add the db-sync tunnel before retrying.
    if [[ -n ${local_backend_port:-} ]]; then
      adb -s "$device" reverse "tcp:$local_backend_port" "tcp:$local_backend_port" >/dev/null 2>&1 || true
    fi
    # Clear stale Maestro instrumentation that may still hold the
    # UiAutomation binding from the failed attempt.
    adb -s "$device" shell am force-stop dev.mobile.maestro >/dev/null 2>&1 || true
    return 0
  fi
  # The emulator process is gone or hung — kill it if still running,
  # then relaunch the runner's AVD.
  local emulator_bin avd
  emulator_bin="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/emulator/emulator"
  avd=$("$emulator_bin" -list-avds 2>/dev/null | head -n 1)
  [[ -n $avd ]] || return 1
  echo "[android-e2e] relaunching emulator @$avd" >&2
  timeout 30 adb -s "$device" emu kill >/dev/null 2>&1 || true
  sleep 2
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
  nohup "$emulator_bin" "@$avd" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot-save >/dev/null 2>&1 &
  timeout 600 adb -s "$device" wait-for-device || return 1
  timeout 180 adb -s "$device" shell \
    'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done' \
    || return 1
  # A fresh boot loses the app and the db-sync tunnel.
  adb -s "$device" install -r \
    "$repo_root/android/app/build/outputs/apk/profile/app-profile.apk" \
    >/dev/null
  if [[ -n ${local_backend_port:-} ]]; then
    adb -s "$device" reverse "tcp:$local_backend_port" "tcp:$local_backend_port"
  fi
  return 0
}

for flow in "${flows[@]}"; do
  echo "==> $flow"
  if [[ $flow = /* ]]; then
    flow_path=$flow
  else
    flow_path="$repo_root/$flow"
  fi
  if [[ ${LOGSEQ_ANDROID_E2E_SKIP_SEED:-0} != 1 ]]; then
    if [[ $flow == "$autocomplete_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$outliner_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$hierarchy_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$audio_flow" ]]; then
      seed_android_fixture --outliner
    elif [[ $flow == "$navigation_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$flashcards_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$search_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$rich_content_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$node_tag_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$page_actions_flow" ]]; then
      seed_android_fixture --fixture
    elif [[ $flow == "$editor_regressions_flow" ]]; then
      seed_android_fixture --outliner
    fi
  fi
  if [[ $flow == "$sharing_flow" ]]; then
    adb -s "$device" shell am start -W \
      -a android.intent.action.SEND \
      -t text/plain \
      --es android.intent.extra.TEXT https://example.com/android-share \
      --es android.intent.extra.TITLE 'Android\ share' \
      "$app_id/.MainActivity" >/dev/null
  elif [[ $flow == "$sharing_image_flow" ]]; then
    share_image="$repo_root/apple/App/Assets.xcassets/AppIcon.appiconset/AppIcon-20~ipad.png"
    [[ -f $share_image ]] || die "Android image-share fixture is missing"
    remote_share_image="/data/local/tmp/logseq-e2e-share.png"
    app_share_image="files/logseq-e2e-share.png"
    adb -s "$device" push "$share_image" "$remote_share_image" >/dev/null
    adb -s "$device" shell run-as "$app_id" cp "$remote_share_image" "$app_share_image"
    adb -s "$device" shell rm -f "$remote_share_image"
    adb -s "$device" shell am start -W \
      -a android.intent.action.SEND \
      -t image/png \
      --eu android.intent.extra.STREAM \
      "file:///data/user/0/$app_id/$app_share_image" \
      "$app_id/.MainActivity" >/dev/null
  fi
  maestro_args=(--device "$device" test)
  if [[ $flow == "$connect_flow" || $flow == "$local_setup_flow" ]]; then
    maestro_args+=(
      -e "USERNAME=$LOGSEQ_E2E_USERNAME"
      -e "PASSWORD=$LOGSEQ_E2E_PASSWORD"
    )
  fi
  adb -s "$device" logcat -c >/dev/null 2>&1 || true
  # A previous flow's Maestro instrumentation (dev.mobile.maestro) can
  # linger and keep the UiAutomation binding — the next driver session
  # then waits the whole startup budget for a binding it can never get.
  # Force-stop the stale driver before each flow.
  adb -s "$device" shell am force-stop dev.mobile.maestro >/dev/null 2>&1 || true
  # The Android driver's default startup budget is only 15s — far too small
  # for a loaded CI emulator (it once failed to come up between two flows).
  # Per-flow retry additionally covers driver/device hiccups;
  # LOGSEQ_ANDROID_E2E_RETRIES=0 runs each flow exactly once.
  flow_retries=${LOGSEQ_ANDROID_E2E_RETRIES:-1}
  flow_attempt=0
  while :; do
    maestro_log=$(mktemp)
    if MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_DRIVER_STARTUP_TIMEOUT=300000 \
      maestro "${maestro_args[@]}" "$flow_path" 2>&1 | tee "$maestro_log"; then
      rm -f "$maestro_log"
      break
    fi
    driver_start_failed=0
    grep -q "AndroidDriverTimeoutException\|driver did not start" \
      "$maestro_log" && driver_start_failed=1
    rm -f "$maestro_log"
    flow_attempt=$((flow_attempt + 1))
    if (( flow_attempt > flow_retries )); then
      # OCaml lui_* FFI exceptions and [NativeEffect] drain traces land in
      # logcat — dump it so a wedged pipeline is diagnosable from CI output.
      echo "==> $flow failed — device logcat follows" >&2
      adb -s "$device" logcat -d -v brief 2>/dev/null | tail -n 400 >&2 || true
      exit 1
    fi
    echo "[android-e2e] $flow failed; retrying ($flow_attempt/$flow_retries)" >&2
    if (( driver_start_failed )); then
      # The driver never bound its port while adb stayed healthy — the
      # instrumentation is wedged, not the channel. Relaunch the emulator
      # for a clean binding rather than force-stopping the stale driver.
      recover_device force || echo "[android-e2e] device recovery failed" >&2
    else
      recover_device || echo "[android-e2e] device recovery failed" >&2
    fi
  done
  if [[ $flow == "$sharing_image_flow" ]]; then
    adb -s "$device" shell run-as "$app_id" rm -f "$app_share_image"
  fi
  if (( needs_primary_button )) \
    && [[ $flow == "$signed_out_flow" ]] \
    && [[ ${LOGSEQ_ANDROID_E2E_SKIP_VISUAL_GATES:-0} != 1 ]]; then
    ANDROID_SERIAL=$device "$repo_root/scripts/test-android-primary-button.sh"
    ANDROID_SERIAL=$device "$repo_root/scripts/test-android-idle-rendering.sh"
  fi
done

echo "Android E2E '$selector' passed (${#flows[@]} flows)"
