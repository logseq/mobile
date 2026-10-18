#!/usr/bin/env python3
"""Verify the discoverable shortcuts and widget extension in an assembled iOS app."""
import json
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
widget = app / "PlugIns/LogseqWidgets.appex"
def metadata(bundle):
    return json.loads((bundle / "Metadata.appintents/extract.actionsdata").read_bytes())

host = metadata(app)
extension = metadata(widget)
expected = {"QuickAddIntent", "RecordAudioIntent", "OpenJournalIntent", "CaptureToJournalIntent"}
shortcuts = [item["actionIdentifier"] for item in host["autoShortcuts"]]
assert set(shortcuts) == expected and len(shortcuts) == len(expected), "Every shortcut needs its own discoverable action"
for identifier in expected:
    assert host["actions"][identifier]["openAppWhenRun"], identifier
for identifier in expected - {"CaptureToJournalIntent"}:
    assert extension["actions"][identifier]["openAppWhenRun"], identifier
info = plistlib.loads((widget / "Info.plist").read_bytes())
host_info = plistlib.loads((app / "Info.plist").read_bytes())
assert info.get("UIDeviceFamily") == [1, 2], "Widget must declare iPhone and iPad support"
assert info.get("CFBundleSupportedPlatforms") == host_info["CFBundleSupportedPlatforms"], "Widget platform must match host"
items = host_info.get("UIApplicationShortcutItems", [])
assert [(item["UIApplicationShortcutItemType"], item["UIApplicationShortcutItemTitle"]) for item in items] == [
    ("logseq://audio", "Voice"), ("logseq://capture", "Quick Add")
], "Home Screen must expose Voice and Quick Add"
assert info["CFBundleIdentifier"] == host_info["CFBundleIdentifier"] + ".shortcuts"
assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
assert (widget / info["CFBundleExecutable"]).is_file()
print("Verified four distinct app shortcuts and the embedded widget extension")
