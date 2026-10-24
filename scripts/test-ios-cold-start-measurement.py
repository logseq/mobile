#!/usr/bin/env python3
"""Reject blank commits and title labels occluded by the native launch cover."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    environment = os.environ.copy()
    environment["LOGSEQ_IOS_CONFIGURATION"] = "release"
    environment["LOGSEQ_IOS_RUNTIME_CHECK_BUNDLE_ID"] = "com.logseq.logseq.ColdStartFrameCheck"
    result = subprocess.run([
        "python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
        str(ROOT / "apple/Tests/UI/cold-start-visible-content.swift"), "VisibleContentCheck",
    ], cwd=ROOT, env=environment, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if result.returncode:
        raise SystemExit(output)
    frames = [json.loads(line.removeprefix("COLD_START_RESULT ")) for line in output.splitlines()
              if line.startswith("COLD_START_RESULT ")]
    revealed = re.findall(r"stage=test_content_revealed process_ms=([\d.]+)", output)
    if len(frames) != 1 or len(revealed) != 1 or frames[0]["nonempty_rows"] != 1:
        raise SystemExit("FAIL: the benchmark accepted blank or covered content\n" + output)
    if frames[0]["first_commit_ms"] < float(revealed[0]):
        raise SystemExit("FAIL: the benchmark committed before content was revealed\n" + output)
    print("PASS: first-frame measurement rejects blank and covered content, then records a visible title")


if __name__ == "__main__":
    main()
