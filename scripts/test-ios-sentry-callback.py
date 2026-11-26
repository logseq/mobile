#!/usr/bin/env python3
"""Run the production Sentry callback off-main on a booted simulator, without XCTest.

Requires a simulator build with LOGSEQ_ENABLE_SENTRY=1.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.logseq.logseq.SentryCallbackCheck"
LOCAL_DSN = "https://public@127.0.0.1:9/0"


def run(args, **kwargs):
    result = subprocess.run(args, **kwargs)
    if result.returncode:
        raise SystemExit(f"Command failed (exit {result.returncode}): {args[0]}")
    return result


def main():
    configuration = os.environ.get("LOGSEQ_IOS_CONFIGURATION", "debug")
    if configuration not in ("debug", "release"):
        raise SystemExit("LOGSEQ_IOS_CONFIGURATION must be debug or release")
    scratch = Path(os.environ.get("LOGSEQ_IOS_SWIFT_SCRATCH_PATH", ROOT / "apple/.build"))
    build = scratch / "arm64-apple-ios-simulator" / configuration
    simulator = os.environ.get("LOGSEQ_IOS_SIMULATOR", "booted")
    installed = subprocess.run(["xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data"], capture_output=True)
    if installed.returncode == 0:
        run(["xcrun", "simctl", "uninstall", simulator, BUNDLE])
    print("SENTRY_CHECK_FRESH_INSTALL", flush=True)
    description = json.loads((build / "description.json").read_text())
    sentry = next((command for command in description["swiftCommands"].values()
                   if command["moduleName"] == "SentrySwift"), None)
    if sentry is None:
        raise SystemExit(f"Build the {configuration} simulator app with LOGSEQ_ENABLE_SENTRY=1")
    # Reuse the SDK's Clang module search paths, not its Swift language mode.
    arguments = sentry["otherArguments"]
    clang = [item for index, value in enumerate(arguments[:-1]) if value == "-Xcc"
             for item in (value, arguments[index + 1])]
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    objects = sorted(str(path) for target in ("SentrySwift", "SentryObjCInternal", "_SentryPrivate", "SentryHeaders")
                     for path in (build / (target + ".build")).rglob("*.o"))
    if not objects:
        raise SystemExit("Build the simulator Swift package first")
    with tempfile.TemporaryDirectory(prefix="logseq-sentry-check-") as temporary:
        app = Path(temporary) / "SentryCallbackCheck.app"
        app.mkdir()
        build_flags = ["-DDEBUG"] if configuration == "debug" else ["-O"]
        run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6",
             *build_flags, "-DLOGSEQ_ENABLE_SENTRY", "-g",
             "-parse-as-library", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
             "-I", str(build / "Modules"), *clang,
             str(ROOT / "apple/Sources/Logseq/LogseqCrashReporting.swift"),
             str(ROOT / "apple/Tests/UI/sentry-callback-isolation.swift"), *objects,
             "-lc++", "-lz", "-o", str(app / "SentryCallbackCheck")])
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "SentryCallbackCheck",
            "CFBundleName": "Sentry callback check", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "MinimumOSVersion": "17.0", "UIDeviceFamily": [1], "UILaunchScreen": {},
        }))
        run(["codesign", "--force", "--sign", "-", str(app)])
        run(["xcrun", "simctl", "install", simulator, str(app)])
        environment = os.environ.copy()
        environment["SIMCTL_CHILD_LOGSEQ_SENTRY_DEBUG"] = "1" if configuration == "debug" else "0"
        environment["SIMCTL_CHILD_NSUnbufferedIO"] = "YES"
        try:
            output = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", "--console",
                                     simulator, BUNDLE], env=environment, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
            print(output.stdout, flush=True)
            if f"SENTRY_CHECK_DSN={LOCAL_DSN}" not in output.stdout:
                raise SystemExit("FAIL: simulator Sentry callback check did not confirm the local-only DSN")
            expected_environment = "development" if configuration == "debug" else "production"
            if f"PASS: crash handler enabled in {expected_environment}" not in output.stdout:
                raise SystemExit("FAIL: simulator Sentry crash handler did not start in the expected environment")
            if "PASS: background beforeSend" not in output.stdout:
                raise SystemExit("FAIL: simulator Sentry callback check did not complete")
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, BUNDLE], capture_output=True)
            run(["xcrun", "simctl", "uninstall", simulator, BUNDLE])
            print("SENTRY_CHECK_UNINSTALLED (cached envelopes removed)", flush=True)


if __name__ == "__main__":
    main()
