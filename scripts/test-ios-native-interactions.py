#!/usr/bin/env python3
"""Run native editor and search interaction fixtures without XCTest."""
from pathlib import Path
import subprocess
import tempfile
import time
root = Path(__file__).resolve().parents[1]
runner = root / "apple/Tests/UI/run-simulator-runtime-check.py"
with tempfile.TemporaryDirectory(prefix="logseq-native-interactions-") as temporary:
    directory = Path(temporary)
    for filename, entry in [("native-menu-projection.swift", "NativeMenuProjectionCheck"),
                            ("outliner-caret-layout.swift", "OutlinerCaretLayoutCheck"),
                            ("outliner-return-handoff.swift", "ReturnHandoffCheck"),
                            ("outliner-backspace-boundary.swift", "OutlinerBackspaceBoundaryCheck"),
                            ("outliner-subtree-selection.swift", "OutlinerSubtreeSelectionCheck"),
                            ("outliner-autosave.swift", "Check")]:
        source = directory / filename
        source.write_text("@testable import Logseq\n" + (root / "apple/Tests/UI" / filename).read_text())
        subprocess.run(["python3", str(runner), str(source), entry], cwd=root, check=True)
    source = directory / "search.swift"
    source.write_text("@testable import Logseq\n" + (root / "apple/Tests/UI/search-presentation.swift").read_text())
    fixture = directory / "fixture"
    fixture.mkdir()
    bundle = "com.logseq.logseq.PageBenchmark"
    try:
        subprocess.run(["python3", str(runner), str(source), "--interactive", str(fixture)], cwd=root, check=True)
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", "booted", bundle, "data"], text=True).strip())
        result = container / "Documents/result.txt"
        deadline = time.monotonic() + 20
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        output = result.read_text() if result.exists() else "FAIL: search check timed out"
        print(output, flush=True)
        if "FAIL" in output or "PASS" not in output:
            raise SystemExit(1)
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", "booted", bundle], capture_output=True)
        subprocess.run(["xcrun", "simctl", "uninstall", "booted", bundle], check=True)
