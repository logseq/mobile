#!/usr/bin/env python3
"""Check session restoration across signed simulator app replacements without personal credentials."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.logseq.logseq.RuntimeCheck"


def main():
    environment = os.environ.copy()
    simulator = environment.get("LOGSEQ_IOS_SIMULATOR", "booted")
    subprocess.run(["xcrun", "simctl", "uninstall", simulator, BUNDLE], capture_output=True)
    outputs = []
    try:
        for phase in range(4):
            environment["SIMCTL_CHILD_LOGSEQ_SESSION_REINSTALL_PHASE"] = str(phase)
            environment["LOGSEQ_RUNTIME_CHECK_KEEP_INSTALLED"] = "1"
            environment["LOGSEQ_RUNTIME_CHECK_LEGACY_KEYCHAIN"] = "1" if phase in (0, 3) else "0"
            result = subprocess.run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                                     str(ROOT / "apple/Tests/UI/session-reinstall.swift"), "SessionReinstall"],
                                    env=environment, capture_output=True, text=True)
            outputs.append(result.stdout)
            print(result.stdout, flush=True)
            if result.returncode:
                print(result.stderr, flush=True)
                result.check_returncode()
        assert "KEYCHAIN_STABLE_REINSTALL=signedIn" in outputs[2]
        print("PASS: replacing the app with the same concrete Keychain group preserves its session")
    finally:
        subprocess.run(["xcrun", "simctl", "uninstall", simulator, BUNDLE], capture_output=True)


if __name__ == "__main__":
    main()
