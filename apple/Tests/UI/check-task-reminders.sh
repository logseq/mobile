#!/usr/bin/env bash
# Feed real core RPC output through the production Swift reminder path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
producer=${1:?Pass the built native core test executable}
simulator=${2:?Pass the isolated simulator UDID}
producer="$(cd "$(dirname "$producer")" && pwd)/$(basename "$producer")"
if [[ -n "${LOGSEQ_RUNTIME_CHECK_ARTIFACTS:-}" ]]; then
  fixture_dir="$LOGSEQ_RUNTIME_CHECK_ARTIFACTS/task-reminders-fixtures"
else
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/logseq-task-reminders.XXXXXX")
fi
mkdir -p "$fixture_dir"
printf 'TASK_REMINDER_FIXTURE_DIR=%s\n' "$fixture_dir"
fixture="$fixture_dir/task-reminders-rpc.json"
date_fixture="$fixture_dir/task-reminders-date-rpc.json"
(
  cd shared/test
  LOGSEQ_TASK_REMINDERS_FIXTURE_PATH="$fixture" "$producer"
  LOGSEQ_TASK_REMINDERS_DATE_FIXTURE_PATH="$date_fixture" "$producer"
)
test -s "$fixture"
test -s "$date_fixture"
LOGSEQ_IOS_SIMULATOR="$simulator" \
LOGSEQ_RUNTIME_CHECK_FIXTURE="$fixture" \
LOGSEQ_RUNTIME_CHECK_DATE_FIXTURE="$date_fixture" \
LOGSEQ_RUNTIME_CHECK_TIMEOUT=90 \
  python3 apple/Tests/UI/run-simulator-runtime-check.py \
    apple/Tests/UI/task-reminders.swift CheckTaskReminders
