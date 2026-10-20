#!/usr/bin/env python3
"""Exercise real iOS share providers and the extension/App Group queue without XCTest."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SIMULATOR = os.environ.get("LOGSEQ_IOS_SIMULATOR", "booted")
BUNDLE = "com.logseq.logseq.ShareProviderCheck"


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="logseq-share-providers-") as temporary:
        directory = Path(temporary)
        app = directory / "ShareProviderCheck.app"
        app.mkdir()
        run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
             str(ROOT / "apple/Sources/Logseq/SharedCapture.swift"),
             str(ROOT / "apple/App/ShareExtension/SharedProviderPolicy.swift"),
             str(ROOT / "apple/App/ShareExtension/ShareViewController.swift"),
             str(ROOT / "apple/Tests/UI/shared-provider-capture.swift"), "-o", str(app / "ShareProviderCheck")])
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "ShareProviderCheck",
            "CFBundleName": "Share provider check", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "MinimumOSVersion": "17.0", "UIDeviceFamily": [1], "UILaunchScreen": {},
        }))
        entitlements = directory / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.application-groups": ["group.com.logseq.logseq"]}))
        run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)])
        run(["xcrun", "simctl", "install", SIMULATOR, str(app)])
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE, "data"], text=True).strip())
        result = container / "Documents/result.txt"
        result.unlink(missing_ok=True)
        try:
            run(["xcrun", "simctl", "launch", "--terminate-running-process", SIMULATOR, BUNDLE])
            deadline = time.monotonic() + 45
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(0.2)
            if not result.exists():
                raise SystemExit("Share provider check did not finish")
            message = result.read_text()
            print(message)
            if not message.startswith("PASS:"):
                raise SystemExit(1)
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", SIMULATOR, BUNDLE], capture_output=True)


if __name__ == "__main__":
    main()
