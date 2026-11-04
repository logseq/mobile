#!/usr/bin/env python3
"""Check real WidgetKit archived layout, which an ImageRenderer preview cannot validate."""
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def validate_render(text, activity_id):
    entries = re.split(r"(?m)(?=^\d{4}-\d{2}-\d{2} \d{2}:)", text)
    rendered = [entry for entry in entries
                if f"[activity:{activity_id}:" in entry
                and "Rendering view: AnyView(_ArchivedView" in entry]
    for presentation in ("listItem", "dynamicIsland-compactTrailing"):
        if not any(f"-{presentation}] Rendering view:" in entry for entry in rendered):
            raise AssertionError(f"The system did not render the recording {presentation}")
    for entry in rendered:
        frame = re.search(r"\(frame \(([^)]+)\)\)", entry)
        if frame is None:
            raise AssertionError("The system-rendered activity has no layout frame")
        values = frame[1].replace(";", " ").split()
        if not all(math.isfinite(float(value)) for value in values):
            raise AssertionError(f"Invalid system activity layout: {frame[0]}")
    return len(rendered)


def main():
    simulator = os.environ.get("LOGSEQ_IOS_SIMULATOR", "booted")
    artifacts = ROOT / "_build/recording-lockscreen-review"
    artifacts.mkdir(parents=True, exist_ok=True)
    render_log = artifacts / "system-render.log"
    check_log = artifacts / "system-check.log"
    environment = os.environ.copy()
    environment.update({
        "LOGSEQ_RUNTIME_CHECK_WIDGETS": "1",
        "SIMCTL_CHILD_LOGSEQ_ACTIVITY_SYSTEM_RENDER": "1",
    })
    with render_log.open("w") as output:
        logger = subprocess.Popen([
            "xcrun", "simctl", "spawn", simulator, "log", "stream", "--level", "debug",
            "--style", "compact", "--predicate", 'process == "WidgetRenderer_Activities"',
        ], stdout=output, stderr=subprocess.STDOUT)
        try:
            result = subprocess.run([
                sys.executable, str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                str(ROOT / "apple/Tests/UI/recording-live-activity.swift"), "CheckRecordingLiveActivity",
            ], env=environment, capture_output=True, text=True, timeout=90)
            check_log.write_text(result.stdout + result.stderr)
            if result.returncode:
                raise SystemExit(f"Live Activity runtime check failed; see {check_log}")
        finally:
            logger.send_signal(signal.SIGINT)
            try:
                logger.wait(timeout=5)
            except subprocess.TimeoutExpired:
                logger.kill()
                logger.wait()
    activity = re.search(r"SYSTEM_ACTIVITY_ID=([^\s]+)", check_log.read_text())
    if activity is None:
        raise SystemExit(f"The runtime check did not return an activity ID; see {check_log}")
    try:
        count = validate_render(render_log.read_text(), activity[1])
    except AssertionError as error:
        raise SystemExit(f"{error}; see {render_log}") from None
    print(f"PASS: {count} system-rendered recording views have finite layout frames, including the lock-screen card and compact timer")


if __name__ == "__main__":
    main()
