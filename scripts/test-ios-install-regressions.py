#!/usr/bin/env python3
"""Check device installation boundaries without installing an app."""
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class DeviceInstallTests(unittest.TestCase):
    def test_production_replacement_requires_explicit_opt_in(self):
        for enabled in ("0", "1"):
            with self.subTest(enabled=enabled):
                env = dict(os.environ, LOGSEQ_IOS_BUNDLE_ID="com.logseq.logseq",
                           LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE=enabled,
                           LOGSEQ_IOS_CONFIG="/tmp/logseq-absent-config")
                env.pop("LOGSEQ_IOS_PROFILE", None)
                result = subprocess.run([str(ROOT / "scripts/install-mobile-ios-device.sh")],
                                        env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                expected = "set LOGSEQ_IOS_PROFILE" if enabled == "1" else "refusing to install"
                self.assertIn(expected, result.stderr)

    def test_production_shortcuts_identifier_passes_bundle_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory)
            widget = app / "PlugIns/LogseqWidgets.appex"
            actions = {name: {"openAppWhenRun": True} for name in
                       ("QuickAddIntent", "RecordAudioIntent", "OpenJournalIntent", "CaptureToJournalIntent")}
            for bundle in (app, widget):
                (bundle / "Metadata.appintents").mkdir(parents=True)
                (bundle / "Metadata.appintents/extract.actionsdata").write_text(json.dumps({
                    "actions": actions,
                    "autoShortcuts": [{"actionIdentifier": name} for name in actions],
                }))
            host = {"CFBundleIdentifier": "com.logseq.logseq", "CFBundleSupportedPlatforms": ["iPhoneOS"],
                    "UIApplicationShortcutItems": [
                        {"UIApplicationShortcutItemType": "logseq://audio", "UIApplicationShortcutItemTitle": "Voice"},
                        {"UIApplicationShortcutItemType": "logseq://capture", "UIApplicationShortcutItemTitle": "Quick Add"},
                    ]}
            info = {"CFBundleIdentifier": "com.logseq.logseq.shortcuts", "UIDeviceFamily": [1, 2],
                    "CFBundleSupportedPlatforms": ["iPhoneOS"], "CFBundleExecutable": "LogseqWidgets",
                    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}
            (app / "Info.plist").write_bytes(plistlib.dumps(host))
            (widget / "Info.plist").write_bytes(plistlib.dumps(info))
            (widget / "LogseqWidgets").touch()
            result = subprocess.run(["python3", str(ROOT / "scripts/verify-ios-shortcuts.py"), str(app)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
