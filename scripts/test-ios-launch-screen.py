#!/usr/bin/env python3
"""Verify Xcode and direct-install builds deliver the same native launch screen."""
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "apple/App/Info.plist"
expected = {"UIColorName": "LaunchBackground", "UIImageName": "LaunchLogo",
            "UIImageRespectsSafeAreaInsets": False}
assert plistlib.loads(source.read_bytes()).get("UILaunchScreen") == expected, \
    "The Xcode app must show the adaptive Logseq logo during system launch"
with tempfile.TemporaryDirectory(prefix="logseq-launch-screen-") as directory:
    for platform in ("iPhoneOS", "iPhoneSimulator"):
        target = Path(directory) / (platform + ".plist")
        shutil.copyfile(source, target)
        for build_number in ("101", "102"):
            subprocess.run([str(ROOT / "scripts/configure-ios-info-plist.sh"), str(target),
                            "com.logseq.logseq.launch-check", "17.0", platform],
                           check=True, capture_output=True,
                           env={**os.environ, "LOGSEQ_IOS_BUILD_NUMBER": build_number})
            assert plistlib.loads(target.read_bytes())["CFBundleVersion"] == build_number, \
                "Each direct install must preserve the requested build identity"
            assert plistlib.loads(target.read_bytes())["UILaunchScreen"] == expected, \
                "Direct-install configuration must preserve the system launch screen"
    target = Path(directory) / "default.plist"
    shutil.copyfile(source, target)
    environment = {key: value for key, value in os.environ.items() if key != "LOGSEQ_IOS_BUILD_NUMBER"}
    subprocess.run([str(ROOT / "scripts/configure-ios-info-plist.sh"), str(target),
                    "com.logseq.logseq.launch-check", "17.0", "iPhoneOS"],
                   check=True, capture_output=True, env=environment)
    version = plistlib.loads(target.read_bytes())["CFBundleVersion"]
    assert version.isdecimal() and int(version) > 1, "Default builds must not reuse the constant build number 1"
print("PASS: Xcode and repeated device/simulator configuration share the adaptive launch logo")
