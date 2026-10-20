#!/bin/zsh
set -euo pipefail

# Requires an app with a selected graph already cached.
# Set LOGSEQ_IOS_DEVICE=iPhone to measure a physical device.
# Restart the process without clearing the graph or authentication state.
# Optionally set LOGSEQ_PROCESS_LAUNCH_BUDGET_MS to include pre-main work in the gate.
device="${LOGSEQ_IOS_SIMULATOR:-booted}"
bundle_id="${LOGSEQ_IOS_BUNDLE_ID:-com.logseq.logseq}"
budget_ms="${LOGSEQ_JOURNALS_READY_BUDGET_MS:-200}"
process_budget_ms="${LOGSEQ_PROCESS_LAUNCH_BUDGET_MS:-}"
launch_log="$(mktemp -t logseq-journals-launch).log"
launch_pid=""

cleanup() {
  if [[ -n "$launch_pid" ]]; then
    kill "$launch_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$launch_log"
}
trap cleanup EXIT

if [[ -n "${LOGSEQ_IOS_DEVICE:-}" ]]; then
  xcrun devicectl device process launch --terminate-existing \
    --device "$LOGSEQ_IOS_DEVICE" --console \
    --environment-variables '{"LOGSEQ_TRACE_STARTUP":"1","LUI_TRACE_APPEAR_IDENTIFIER":"journals.graph-loaded"}' \
    "$bundle_id" >"$launch_log" 2>&1 &
else
  xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
  SIMCTL_CHILD_LUI_TRACE_APPEAR_IDENTIFIER=journals.graph-loaded SIMCTL_CHILD_LOGSEQ_TRACE_STARTUP=1 \
    xcrun simctl launch --console-pty "$device" "$bundle_id" >"$launch_log" 2>&1 &
fi
launch_pid="$!"

for _ in {1..300}; do
  if grep -q "LUI_APPEAR_METRIC identifier=journals.graph-loaded timestamp=" "$launch_log" \
     && grep -q "LOGSEQ_LAUNCH_METRIC first_ui_rendered_ms=" "$launch_log"; then
    break
  fi
  if ! kill -0 "$launch_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

metric="$(python3 - "$launch_log" <<'PYTHON'
import re, sys
text = open(sys.argv[1]).read()
start = re.search(r"LOGSEQ_LAUNCH_METRIC start=([0-9.]+)", text)
ready = re.search(r"LUI_APPEAR_METRIC identifier=journals.graph-loaded timestamp=([0-9.]+)", text)
if start and ready:
    print(f"{(float(ready[1]) - float(start[1])) * 1000:.3f}")
PYTHON
)"
if [[ -z "$metric" ]]; then
  print -u2 "journals onAppear launch metric was not emitted"
  cat "$launch_log" >&2
  exit 1
fi

for stage in local_load_started catalog_opened graph_configured open_graph_started open_graph_returned; do
  if ! grep -q "LOGSEQ_LAUNCH_METRIC ${stage}_ms=" "$launch_log"; then
    print -u2 "missing launch stage metric: $stage"
    cat "$launch_log" >&2
    exit 1
  fi
done

if ! grep -q "LOGSEQ_LAUNCH_APPLY_METRIC action=openGraph" "$launch_log"; then
  print -u2 "missing openGraph response apply metric"
  cat "$launch_log" >&2
  exit 1
fi

apply_count="$(grep -c 'LOGSEQ_LAUNCH_APPLY_METRIC action=openGraph' "$launch_log")"
if [[ "$apply_count" != 1 ]]; then
  print -u2 "local launch response must be applied once, got $apply_count"
  cat "$launch_log" >&2
  exit 1
fi

python3 - "$launch_log" <<'PYTHON'
import re, sys
text = open(sys.argv[1]).read()
def stage(name):
    match = re.search(r"LOGSEQ_LAUNCH_METRIC " + name + r"_ms=([0-9.]+)", text)
    if not match:
        sys.exit("missing launch stage: " + name)
    return float(match[1])
start = re.search(r"LOGSEQ_LAUNCH_METRIC start=([0-9.]+)", text)
appearances = re.findall(r"LUI_APPEAR_METRIC identifier=journals.graph-loaded timestamp=([0-9.]+)", text)
if len(appearances) != 1:
    sys.exit("journals must appear once during startup")
appeared_ms = (float(appearances[0]) - float(start[1])) * 1000
if stage("store_opened") > appeared_ms or stage("store_opened") > stage("first_ui_rendered"):
    sys.exit("the first UI must receive the complete local snapshot synchronously")
PYTHON

grep -E '(LOGSEQ_.*METRIC|LOGSEQ_LAUNCH_STEP|LUI_APPEAR_METRIC)' "$launch_log"

awk -v actual="$metric" -v budget="$budget_ms" 'BEGIN {
  if (actual > budget) {
    printf "journals onAppear exceeded budget: %.3fms > %.3fms\n", actual, budget > "/dev/stderr"
    exit 1
  }
  printf "journals onAppear: %.3fms (budget %.3fms)\n", actual, budget
}'

# This includes pre-main work, unlike the application-initialization timer above.
# The callback is a UI lifecycle milestone, not a GPU presentation timestamp.
if [[ -n "$process_budget_ms" ]]; then
  python3 - "$launch_log" "$process_budget_ms" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"LOGSEQ_PROCESS_LAUNCH_METRIC first_ui_rendered_ms=([0-9.]+)", text)
if not match:
    sys.exit("missing process launch metric; install a build with process timing enabled")
actual, budget = float(match[1]), float(sys.argv[2])
print(f"process creation to first UI callback: {actual:.3f}ms (budget {budget:.3f}ms)")
if actual > budget:
    sys.exit("process launch exceeded budget")
PY
fi
