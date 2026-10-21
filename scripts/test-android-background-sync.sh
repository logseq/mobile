#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
serial=${1:-emulator-5556}
[[ $serial == emulator-* ]] || { echo "This isolated QA flow only accepts an emulator" >&2; exit 1; }
adb=(adb -s "$serial")
app_id=com.logseq.app
seed="$repo_root/_build/default/shared/native/logseq_e2e_seed.exe"
[[ -x $seed ]] || { echo "Build shared/native/logseq_e2e_seed.exe before this flow" >&2; exit 1; }

# Clone only the dedicated QA graph; never modify the selected graph's database.
"${adb[@]}" exec-out run-as "$app_id" cat shared_prefs/logseq.xml | python3 -c '
import sys, xml.etree.ElementTree as E
root = E.parse(sys.stdin).getroot()
assert any(x.get("name") == "logseq.selectedGraphId" and x.text == "uiregression" for x in root), "The dedicated QA graph must be selected"
'
task_dir=$(mktemp -d /tmp/logseq-background-sync.XXXXXX)
trap 'rm -rf "$task_dir"' EXIT
"${adb[@]}" shell am force-stop "$app_id"
graph_dir=files/graphs/UI_Regression-uiregression
"${adb[@]}" exec-out run-as "$app_id" cat "$graph_dir/graph.sqlite" > "$task_dir/graph.sqlite"
for suffix in -wal -shm; do
    if "${adb[@]}" shell run-as "$app_id" test -f "$graph_dir/graph.sqlite$suffix"; then
        "${adb[@]}" exec-out run-as "$app_id" cat "$graph_dir/graph.sqlite$suffix" > "$task_dir/graph.sqlite$suffix"
    fi
done
python3 - "$task_dir/graph.sqlite" <<'PYTHON'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as database:
    tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for table in ("logseq_pending_op_dependencies", "logseq_pending_txs", "logseq_pending_ops", "logseq_sync_state"):
        if table in tables:
            database.execute("DELETE FROM " + table)
    database.commit()
    database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
PYTHON
"$seed" "$task_dir/graph.sqlite" --composer
"${adb[@]}" push "$task_dir/graph.sqlite" /data/local/tmp/logseq-background-sync.sqlite
"${adb[@]}" shell am instrument -w -r \
    -e class com.logseq.app.AndroidBackgroundSyncTest \
    -e backgroundGraphFixture /data/local/tmp/logseq-background-sync.sqlite \
    "$app_id.test/androidx.test.runner.AndroidJUnitRunner" | tee "$task_dir/result.log"
python3 - "$task_dir/result.log" <<'PYTHON'
import re, sys
result = open(sys.argv[1]).read()
assert re.search(r"^OK \([1-9][0-9]* tests?\)", result, re.M), result
assert "FAILURES!!!" not in result, result
PYTHON
