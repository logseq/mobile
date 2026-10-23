#!/usr/bin/env python3
"""Run native launch regressions with a real isolated graph; never invokes XCTest."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"


def main():
    environment = os.environ.copy()
    environment.setdefault("LOGSEQ_IOS_CONFIGURATION", "release")
    environment["LOGSEQ_IOS_RUNTIME_CHECK_BUNDLE_ID"] = "com.logseq.logseq.ColdStartLaunchCheck"
    fixture_bundle = "com.logseq.logseq.ColdStartLaunchFixture"
    environment["LOGSEQ_IOS_BENCHMARK_BUNDLE_ID"] = fixture_bundle
    simulator = environment.get("LOGSEQ_IOS_SIMULATOR", "booted")
    # Build with test visibility and validate the consuming UI before native checks.
    subprocess.run([sys.executable, str(ROOT / "scripts/test-swift-ui-suite.py")],
                   cwd=ROOT, env=environment, check=True)
    for filename, entry in [
        ("launch-transition.swift", "LaunchTransitionCheck"),
        ("first-content-frame.swift", "FirstContentFrameCheck"),
        ("drawer-first-reveal.swift", "DrawerFirstRevealCheck"),
        ("file-preview-launch.swift", "FilePreviewLaunchCheck"),
        ("authentication-launch.swift", "AuthenticationLaunchCheck"),
    ]:
        subprocess.run([sys.executable, str(RUNNER), str(ROOT / "apple/Tests/UI" / filename), entry],
                       cwd=ROOT, env=environment, check=True)
    with tempfile.TemporaryDirectory(prefix="logseq-launch-checks-") as temporary:
        fixture = Path(temporary) / "fixture"
        subprocess.run(["opam", "exec", "--switch=5.5.0", "--", "dune", "exec", "--profile=release",
                        "shared/bench/page_fixture.exe", "--", str(fixture), "20"], cwd=ROOT, check=True)
        try:
            for filename in ["first-frame-deferred-work.swift", "host-snapshot-projection.swift"]:
                subprocess.run([sys.executable, str(RUNNER), str(ROOT / "apple/Tests/UI" / filename),
                                "--benchmark", str(fixture)], cwd=ROOT, env=environment, check=True)
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, fixture_bundle],
                           capture_output=True)
            subprocess.run(["xcrun", "simctl", "uninstall", simulator, fixture_bundle],
                           capture_output=True)


if __name__ == "__main__":
    main()
