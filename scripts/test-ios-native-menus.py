#!/usr/bin/env python3
"""Exercise real native composer menus, platform effects and system presentations."""
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.logseq.logseq.PageBenchmark"
SIMULATOR = os.environ.get("LOGSEQ_IOS_SIMULATOR", "booted")
HIT_TESTING_ONLY = "--hit-testing" in sys.argv[1:]
OUTPUT = Path(os.environ.get("LOGSEQ_MENU_TEST_OUTPUT", "/tmp/logseq-native-menu-results"))


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="logseq-native-menus-") as temporary:
    directory = Path(temporary)
    fixture = directory / "fixture"
    fixture.mkdir()
    flow = directory / "menus.yaml"
    flow_name = "ios-composer-hit-testing.yaml" if HIT_TESTING_ONLY else "ios-composer-native-menus.yaml"
    flow.write_text((ROOT / "tests/e2e" / flow_name).read_text().replace(
        "appId: com.logseq.logseq\n", f"appId: {BUNDLE}\n"))
    try:
        run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
             str(ROOT / "apple/Tests/UI/native-menu-presentation.swift"), "--interactive", str(fixture)])
        for service in ("microphone", "camera"):
            run(["xcrun", "simctl", "privacy", SIMULATOR, "grant", service, BUNDLE])
        run(["xcrun", "simctl", "launch", "--terminate-running-process", SIMULATOR, BUNDLE])
        command = ["maestro"]
        if SIMULATOR != "booted":
            command += ["--udid", SIMULATOR]
        run([*command, "test", str(flow), "--debug-output", str(OUTPUT)])
        container = Path(subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE, "data"], text=True).strip())
        events = (container / "Documents/presentation.txt").read_text().splitlines()
        assert events.count("EVENT press spacer.composer.controls") == 1, "The composer blank-space focus tap was intercepted: " + str(events)
        assert "EVENT press " not in events, "A control tap reached the composer ancestor"
        if HIT_TESTING_ONLY:
            assert events.count("REQUEST files") == 1, events
            assert "EVENT extension native-navigation-stack dismiss-composer" not in events, events
            print("PASS: composer blank space receives its tap and a single menu selection presents Files")
            sys.exit(0)
        for service, count in (("photos", 3), ("audio", 3), ("camera", 1), ("files", 1)):
            assert events.count("REQUEST " + service) == count, (service, events)
        assets = [json.loads(line.removeprefix("STAGED ")) for line in events if line.startswith("STAGED ")]
        assert any(asset["assetType"] == "m4a" and asset["assetSize"] > 0 for asset in assets), assets
        for status in ("backlog", "todo", "doing", "in-review", "done", "canceled"):
            assert any(line.startswith("EVENT press button.task-status.option.") and status in line
                       for line in events), (status, events)
        assert "EVENT press button.task-status.clear" in events, events
        assert events.count("EVENT press menu.graph.other") == 1, events
        print("PASS: single-tap native menus, all attachment presentations, repeated dismissal, audio staging, every task status and native sidebar graph switching")
    finally:
        container = subprocess.run(["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE, "data"],
                                   capture_output=True, text=True)
        if container.returncode == 0:
            events = Path(container.stdout.strip()) / "Documents/presentation.txt"
            if events.exists():
                OUTPUT.mkdir(parents=True, exist_ok=True)
                (OUTPUT / "presentation.txt").write_text(events.read_text())
        subprocess.run(["xcrun", "simctl", "terminate", SIMULATOR, BUNDLE], capture_output=True)
        subprocess.run(["xcrun", "simctl", "uninstall", SIMULATOR, BUNDLE], capture_output=True)
