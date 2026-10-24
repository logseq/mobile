#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

all_flows=(
  tests/e2e/ios-capture-responsive.yaml
  tests/e2e/ios-send-regression.yaml
  tests/e2e/ios-cold-start-composer.yaml
  tests/e2e/ios-outliner-mode.yaml
  tests/e2e/ios-page-outliner-only.yaml
  tests/e2e/ios-search-status-regression.yaml
  tests/e2e/sidebar.yaml
  tests/e2e/ios-outliner-interactions.yaml
  tests/e2e/ios-outliner-editor-toolbar.yaml
  tests/e2e/ios-outliner-autocomplete-completion.yaml
  tests/e2e/ios-outliner-continuous-editing.yaml
  tests/e2e/ios-outliner-empty-block-caret.yaml
  tests/e2e/ios-outliner-fixture-edit-baseline.yaml
  tests/e2e/ios-invalid-order-bounds-regression.yaml
  tests/e2e/ios-outliner-selection-toolbar.yaml
  tests/e2e/ios-outliner-hierarchy-navigation.yaml
  tests/e2e/ios-node-tag-navigation.yaml
  tests/e2e/ios-native-header-navigation.yaml
  tests/e2e/ios-sidebar-node-navigation.yaml
  tests/e2e/ios-page-share.yaml
  tests/e2e/ios-page-favorite.yaml
  tests/e2e/ios-settings-theme-parity.yaml
  tests/e2e/ios-settings-tabs.yaml
  tests/e2e/ios-sidebar-page-empty-block-delete.yaml
  tests/e2e/ios-rich-block-rendering.yaml
  tests/e2e/ios-flashcard-decks.yaml
  tests/e2e/ios-flashcards-regression.yaml
  tests/e2e/ios-outliner-drag.yaml
  tests/e2e/ios-graphs.yaml
  tests/e2e/ios-graphs-lifecycle.yaml
  tests/e2e/ios-sync-graph-create-regression.yaml
)

selector=${1:-${LOGSEQ_IOS_E2E_MODULE:-all}}
case $selector in
  all)
    flows=("${all_flows[@]}")
    ;;
  smoke)
    flows=(
      tests/e2e/ios-capture-responsive.yaml
      tests/e2e/ios-cold-start-composer.yaml
      tests/e2e/ios-search-status-regression.yaml
      tests/e2e/sidebar.yaml
    )
    ;;
  composer)
    flows=(
      tests/e2e/ios-capture-responsive.yaml
      tests/e2e/ios-send-regression.yaml
      tests/e2e/ios-cold-start-composer.yaml
    )
    ;;
  outliner)
    flows=(
      tests/e2e/ios-outliner-mode.yaml
      tests/e2e/ios-page-outliner-only.yaml
      tests/e2e/ios-outliner-interactions.yaml
      tests/e2e/ios-outliner-editor-toolbar.yaml
      tests/e2e/ios-outliner-autocomplete-completion.yaml
      tests/e2e/ios-outliner-continuous-editing.yaml
      tests/e2e/ios-outliner-empty-block-caret.yaml
      tests/e2e/ios-outliner-fixture-edit-baseline.yaml
      tests/e2e/ios-invalid-order-bounds-regression.yaml
      tests/e2e/ios-outliner-selection-toolbar.yaml
      tests/e2e/ios-outliner-hierarchy-navigation.yaml
      tests/e2e/ios-sidebar-page-empty-block-delete.yaml
      tests/e2e/ios-outliner-drag.yaml
    )
    ;;
  navigation)
    flows=(
      tests/e2e/ios-node-tag-navigation.yaml
      tests/e2e/ios-native-header-navigation.yaml
      tests/e2e/ios-sidebar-node-navigation.yaml
      tests/e2e/ios-page-share.yaml
      tests/e2e/ios-page-favorite.yaml
    )
    ;;
  settings)
    flows=(
      tests/e2e/ios-settings-theme-parity.yaml
      tests/e2e/ios-settings-tabs.yaml
    )
    ;;
  content)
    flows=(tests/e2e/ios-rich-block-rendering.yaml)
    ;;
  flashcards)
    flows=(
      tests/e2e/ios-flashcard-decks.yaml
      tests/e2e/ios-flashcards-regression.yaml
    )
    ;;
  graphs)
    flows=(
      tests/e2e/ios-graphs.yaml
      tests/e2e/ios-graphs-lifecycle.yaml
      tests/e2e/ios-sync-graph-create-regression.yaml
    )
    ;;
  --list)
    echo "Modules: all smoke composer outliner navigation settings content flashcards graphs"
    printf '%s\n' "${all_flows[@]}"
    exit 0
    ;;
  *.yaml)
    if [[ $selector = /* ]]; then
      flow_path=$selector
    else
      flow_path="$repo_root/$selector"
    fi
    [[ -f $flow_path ]] || {
      echo "error: iOS E2E flow not found: $selector" >&2
      exit 1
    }
    flows=("$selector")
    ;;
  *)
    echo "error: unknown iOS E2E module or flow: $selector" >&2
    echo "run '$0 --list' to see available modules and flows" >&2
    exit 1
    ;;
esac

if [[ ${LOGSEQ_IOS_SKIP_BUILD:-0} != 1 ]]; then
  "$repo_root/scripts/build-mobile-ios-simulator.sh" >/dev/null
fi

# One run id for every flow in this suite so graph names are stable, plus a
# shared seed cache: the first flow per fixture mode drives the graph-setup
# flow and caches the seeded graphs dir; later flows copy it into a fresh
# container instead of re-running the Maestro setup.
export LOGSEQ_E2E_RUN_ID=${LOGSEQ_E2E_RUN_ID:-$(date +%s)}
if [[ ${LOGSEQ_E2E_SEED_CACHE:-unset} == unset ]]; then
  seed_cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-e2e-seed-cache.XXXXXX")
  export LOGSEQ_E2E_SEED_CACHE=$seed_cache_dir
  trap 'rm -rf "$seed_cache_dir"' EXIT
fi

start_index=${LOGSEQ_IOS_E2E_START_INDEX:-0}
if (( start_index < 0 || start_index >= ${#flows[@]} )); then
  echo "error: LOGSEQ_IOS_E2E_START_INDEX must be between 0 and $((${#flows[@]} - 1))" >&2
  exit 1
fi

for ((flow_index = start_index; flow_index < ${#flows[@]}; flow_index++)); do
  flow=${flows[$flow_index]}
  echo "==> $flow"
  if [[ $flow == tests/e2e/ios-page-outliner-only.yaml \
     || $flow == tests/e2e/ios-invalid-order-bounds-regression.yaml \
     || $flow == tests/e2e/ios-outliner-empty-block-caret.yaml \
     || $flow == tests/e2e/ios-outliner-fixture-edit-baseline.yaml \
     || $flow == tests/e2e/ios-node-tag-navigation.yaml \
     || $flow == tests/e2e/ios-sidebar-node-navigation.yaml \
     || $flow == tests/e2e/ios-page-share.yaml \
     || $flow == tests/e2e/ios-page-favorite.yaml \
     || $flow == tests/e2e/ios-sidebar-page-empty-block-delete.yaml \
     || $flow == tests/e2e/ios-rich-block-rendering.yaml \
     || $flow == tests/e2e/ios-flashcard-decks.yaml \
     || $flow == tests/e2e/ios-flashcards-regression.yaml \
     || $flow == tests/e2e/ios-capture-responsive.yaml \
     || $flow == tests/e2e/ios-cold-start-composer.yaml \
     || $flow == tests/e2e/ios-search-status-regression.yaml \
     || $flow == tests/e2e/sidebar.yaml ]]; then
    LOGSEQ_IOS_SKIP_BUILD=1 \
      LOGSEQ_IOS_E2E_SEED_GRAPH=1 \
      LOGSEQ_IOS_E2E_FLOW="$flow" \
      "$repo_root/scripts/test-ios-e2e.sh"
  else
    LOGSEQ_IOS_SKIP_BUILD=1 \
      LOGSEQ_IOS_E2E_FLOW="$flow" \
      "$repo_root/scripts/test-ios-e2e.sh"
  fi
done

echo "iOS Simulator E2E '$selector' passed ($((${#flows[@]} - start_index)) flows)"
