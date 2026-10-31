#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flow=${LOGSEQ_IOS_E2E_FLOW:-tests/e2e/ios-capture-responsive.yaml}
app_id=${LOGSEQ_IOS_APP_ID:-com.logseq.logseq}
app_path=${LOGSEQ_IOS_APP_PATH:-$repo_root/apple/.build/Logseq.app}
screenshots_dir="$repo_root/tests/e2e/screenshots"
username=${LOGSEQ_E2E_USERNAME:-e2etest}
password=${LOGSEQ_E2E_PASSWORD:-Logseq-e2e}
e2ee_password=${LOGSEQ_E2EE_PASSWORD:-$password}
run_id=${LOGSEQ_E2E_RUN_ID:-$(date +%s)}
base_url=${LOGSEQ_E2E_BASE_URL:-http://127.0.0.1:8787}
graph_name=${LOGSEQ_IOS_E2E_GRAPH_NAME:-sync-$run_id}
fixture_seed_mode=""
case ${flow##*/} in
  ios-native-header-navigation.yaml)
    graph_name=${LOGSEQ_IOS_E2E_GRAPH_NAME:-logseq-local-e2e-header-$run_id}
    fixture_seed_mode=--header-navigation
    ;;
  ios-capture-responsive.yaml|ios-send-regression.yaml|ios-cold-start-composer.yaml|ios-search-status-regression.yaml|sidebar.yaml)
    graph_name=${LOGSEQ_IOS_E2E_GRAPH_NAME:-logseq-local-e2e-composer-$run_id}
    # These flows write through the sync API. Keep the server's real graph
    # identities instead of replacing its pages with local-only fixture UUIDs.
    fixture_seed_mode=--live
    ;;
  ios-outliner-mode.yaml|ios-outliner-interactions.yaml|\
  ios-outliner-editor-toolbar.yaml|ios-outliner-continuous-editing.yaml|\
  ios-outliner-autocomplete-completion.yaml|ios-outliner-autocomplete-visual.yaml|\
  ios-outliner-selection-toolbar.yaml|ios-outliner-hierarchy-navigation.yaml|\
  ios-outliner-drag.yaml)
    graph_name=${LOGSEQ_IOS_E2E_GRAPH_NAME:-logseq-local-e2e-outliner-$run_id}
    fixture_seed_mode=--outliner
    ;;
  ios-search-navigation.yaml|ios-page-outliner-only.yaml|ios-outliner-empty-block-caret.yaml|\
  ios-outliner-fixture-edit-baseline.yaml|ios-invalid-order-bounds-regression.yaml|\
  ios-sidebar-page-empty-block-delete.yaml|ios-node-tag-navigation.yaml|\
  ios-sidebar-node-navigation.yaml|ios-page-share.yaml|ios-page-favorite.yaml|\
  ios-rich-block-rendering.yaml|ios-flashcard-decks.yaml|ios-flashcards-regression.yaml)
    graph_name=${LOGSEQ_IOS_E2E_GRAPH_NAME:-logseq-local-e2e-fixtures-$run_id}
    fixture_seed_mode=--fixture
    ;;
esac

die() {
  echo "error: $*" >&2
  exit 1
}

maestro_bin=${MAESTRO_BIN:-}
if [[ -z $maestro_bin ]]; then
  if command -v maestro >/dev/null 2>&1; then
    maestro_bin=$(command -v maestro)
  else
    maestro_bin=$(find /opt/homebrew/Cellar/maestro -path '*/bin/maestro' -type f 2>/dev/null | sort -V | tail -1)
  fi
fi
[[ -n $maestro_bin && -x $maestro_bin ]] \
  || die "Maestro CLI is not installed. Install it with: brew install mobile-dev-inc/tap/maestro --formula"

# The setup flow drives the Cognito hosted UI in the system browser, where
# hierarchy queries occasionally stall or crash the XCTest driver on a
# loaded runner. Retry the setup once so a driver flake does not fail the
# whole suite; LOGSEQ_IOS_E2E_SETUP_RETRIES=0 disables the retry.
setup_retries=${LOGSEQ_IOS_E2E_SETUP_RETRIES:-1}
run_maestro_test() {
  if [[ -n ${LOGSEQ_IOS_E2E_DRIVER_PORT:-} ]]; then
    set -- --no-reinstall-driver --driver-host-port="$LOGSEQ_IOS_E2E_DRIVER_PORT" "$@"
  fi
  MAESTRO_CLI_NO_ANALYTICS=1 "$maestro_bin" --device "$device" test "$@"
}

run_setup_flow() {
  local attempt=0
  while :; do
    if run_maestro_test "$rendered_setup"; then
      return 0
    fi
    attempt=$((attempt + 1))
    if (( attempt > setup_retries )); then
      return 1
    fi
    echo "[ios-e2e] setup flow failed; retrying ($attempt/$setup_retries)" >&2
  done
}

device=${LOGSEQ_IOS_SIMULATOR_UDID:-}
if [[ -z $device ]]; then
  device=$(
    xcrun simctl list devices booted \
      | awk -F'[()]' '/Booted/ { print $2; exit }'
  )
fi
[[ -n $device ]] || die "no booted iOS simulator was found"

if [[ ${LOGSEQ_IOS_SKIP_BUILD:-0} != 1 ]]; then
  "$repo_root/scripts/build-mobile-ios-simulator.sh" >/dev/null
fi
# Reset app state between flows by wiping the data container instead of
# reinstalling the (unchanged) binary — a copy of the .app bundle is the
# slowest part of per-flow setup. LOGSEQ_IOS_E2E_REINSTALL=1 restores
# the old uninstall+install behavior.
xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true
if [[ ${LOGSEQ_IOS_E2E_REINSTALL:-0} == 1 ]]; then
  xcrun simctl uninstall "$device" "$app_id" >/dev/null 2>&1 || true
fi
data_container=$(xcrun simctl get_app_container "$device" "$app_id" data 2>/dev/null || true)
if [[ -n $data_container && -d $data_container ]]; then
  rm -rf "$data_container/Documents" "$data_container/Library" "$data_container/tmp"
  # iOS guarantees <container>/tmp exists at runtime; the core writes the
  # initial graph snapshot there via Filename.temp_file.
  mkdir -p "$data_container/tmp"
fi
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.baseURL >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.selectedGraphId >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.composerDraft >/dev/null 2>&1 || true
xcrun simctl spawn "$device" defaults delete "$app_id" logseq.contentMode >/dev/null 2>&1 || true
[[ -d $app_path ]] || die "iOS app bundle was not found: $app_path"
if [[ -z $data_container ]]; then
  xcrun simctl install "$device" "$app_path"
fi
xcrun simctl spawn "$device" defaults write "$app_id" logseq.baseURL "$base_url"

mkdir -p "$screenshots_dir"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/logseq-ios-e2e.XXXXXX")
rendered_flow="$temporary_directory/flow.yaml"
rendered_setup="$temporary_directory/setup.yaml"
rendered_outliner_anchor="$temporary_directory/outliner-anchor.yaml"
rendered_graphs_lifecycle_fixture="$temporary_directory/graphs-lifecycle-fixture.yaml"
trap 'rm -rf "$temporary_directory"' EXIT
if [[ $flow = /* ]]; then
  flow_path=$flow
else
  flow_path="$repo_root/$flow"
fi
sed \
  -e "s|__LOGSEQ_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_E2E_PASSWORD__|$password|g" \
  -e "s|__LOGSEQ_E2EE_PASSWORD__|$e2ee_password|g" \
  -e "s|__LOGSEQ_E2E_GRAPH_NAME__|$graph_name|g" \
  "$repo_root/tests/e2e/ios-local-graph-setup.yaml" > "$rendered_setup"
sed \
  -e "s|__LOGSEQ_E2E_RUN_ID__|$run_id|g" \
  "$repo_root/tests/e2e/ios-outliner-anchor-setup.yaml" > "$rendered_outliner_anchor"
cp \
  "$repo_root/tests/e2e/ios-graphs-lifecycle-fixture-setup.yaml" \
  "$rendered_graphs_lifecycle_fixture"
sed \
  -e "s|__LOGSEQ_E2E_USERNAME__|$username|g" \
  -e "s|__LOGSEQ_E2E_PASSWORD__|$password|g" \
  -e "s|__LOGSEQ_E2E_RUN_ID__|$run_id|g" \
  -e "s|__LOGSEQ_E2E_SETUP_FLOW__|$rendered_setup|g" \
  -e "s|__LOGSEQ_E2E_OUTLINER_ANCHOR_FLOW__|$rendered_outliner_anchor|g" \
  "$flow_path" > "$rendered_flow"
# The graph-setup Maestro flow + sqlite/checkpoint wait is the slowest part
# of a seeded flow (~30-60s). When LOGSEQ_E2E_SEED_CACHE points at a
# directory, the seeded Documents/graphs tree is cached per fixture mode and
# copied into a fresh container on the next flow instead of re-driving the
# UI setup. The suite script sets this up so the cache spans the whole run.
seed_cache_dir=${LOGSEQ_E2E_SEED_CACHE:-}
seed_cache_key=${fixture_seed_mode:-default}-$graph_name
if [[ ${LOGSEQ_IOS_E2E_SEED_GRAPH:-0} == 1 || -n $fixture_seed_mode ]]; then
  if [[ -n $seed_cache_dir && -d $seed_cache_dir/$seed_cache_key/graphs ]]; then
    data_container=$(xcrun simctl get_app_container "$device" "$app_id" data)
    mkdir -p "$data_container/Documents"
    cp -R "$seed_cache_dir/$seed_cache_key/graphs" "$data_container/Documents/"
  else
    run_setup_flow
    data_container=$(xcrun simctl get_app_container "$device" "$app_id" data)
    graph_database=""
    for _ in {1..120}; do
      if [[ -d $data_container/Documents/graphs ]]; then
        graph_database=$(find "$data_container/Documents/graphs" -name graph.sqlite -type f | head -1)
      fi
      if [[ -n $graph_database && -f ${graph_database%/graph.sqlite}/sync.checkpoint ]]; then
        break
      fi
      sleep 0.5
    done
    [[ -n $graph_database && -f ${graph_database%/graph.sqlite}/sync.checkpoint ]] \
      || die "timed out waiting for the graph snapshot import to finish"
    xcrun simctl terminate "$device" "$app_id" >/dev/null 2>&1 || true
    if [[ $fixture_seed_mode == --live ]]; then
      echo "[ios-e2e] preserving the server-backed graph for capture flows"
    elif [[ -n ${LOGSEQ_E2E_SEED_BIN:-} ]]; then
      [[ -x $LOGSEQ_E2E_SEED_BIN ]] || die "E2E seed executable was not found: $LOGSEQ_E2E_SEED_BIN"
      seed_command=("$LOGSEQ_E2E_SEED_BIN")
    elif command -v dune >/dev/null 2>&1; then
      seed_command=(dune exec shared/native/logseq_e2e_seed.exe --)
    else
      seed_command=(opam exec --switch=5.5.0 -- dune exec shared/native/logseq_e2e_seed.exe --)
    fi
    if [[ $fixture_seed_mode != --live ]]; then
      if [[ -n $fixture_seed_mode ]]; then
        "${seed_command[@]}" "$graph_database" "$fixture_seed_mode"
      else
        "${seed_command[@]}" "$graph_database"
      fi
    fi
    if [[ -n $seed_cache_dir ]]; then
      mkdir -p "$seed_cache_dir/$seed_cache_key"
      cp -R "$data_container/Documents/graphs" "$seed_cache_dir/$seed_cache_key/"
    fi
  fi
  # The graph is already provisioned. Cached fixtures only need selection,
  # not another authentication/graph-creation pass inside the tested flow.
  cat > "$rendered_setup" <<EOF
appId: $app_id
---
- launchApp
- runFlow:
    when:
      visible: "$graph_name"
    commands:
      - tapOn: "$graph_name"
- extendedWaitUntil:
    visible:
      id: "button.sidebar"
    timeout: 30000
EOF
fi
if [[ ${flow##*/} == ios-graphs-lifecycle.yaml ]]; then
  run_setup_flow
  run_maestro_test "$rendered_graphs_lifecycle_fixture"
fi
run_maestro_test "$rendered_flow"
xcrun simctl io "$device" screenshot "$screenshots_dir/ios-e2e-final.png" >/dev/null

echo "$screenshots_dir/ios-e2e-final.png"
