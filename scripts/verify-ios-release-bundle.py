#!/usr/bin/env python3
"""Check the signed archive and exported IPA before uploading to TestFlight."""

import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


EXTENSIONS = {
    "LogseqWidgets.appex": ("com.logseq.logseq.shortcuts", "com.apple.widgetkit-extension"),
    "LogseqShareExtension.appex": ("com.logseq.logseq.ShareViewController", "com.apple.share-services"),
}
WIDGET_ACTIONS = {"QuickAddIntent", "RecordAudioIntent", "OpenJournalIntent"}
APP_ACTIONS = WIDGET_ACTIONS | {"CaptureToJournalIntent"}
WIDGET_KINDS = {
    "TodayJournalWidget", "CaptureWidget",
    "com.logseq.logseq.quickAdd", "com.logseq.logseq.recordAudio",
}
TEAM = "K378MFWK59"
APP_GROUP = "group.com.logseq.logseq"


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def read_info(bundle):
    path = bundle / "Info.plist"
    require(path.is_file(), f"Missing bundle Info.plist: {bundle}")
    return plistlib.loads(path.read_bytes())


def read_intents(bundle, required):
    path = bundle / "Metadata.appintents/extract.actionsdata"
    require(path.is_file(), f"Missing App Intents metadata: {bundle.name}")
    metadata = json.loads(path.read_bytes())
    missing = required - metadata.get("actions", {}).keys()
    require(not missing, f"Missing App Intents in {bundle.name}: {sorted(missing)}")
    return metadata


def verify_app(app, args):
    info = read_info(app)
    version = args.version or info["CFBundleShortVersionString"]
    build = args.build or info["CFBundleVersion"]
    if args.revision:
        require(info.get("LogseqRevision") == args.revision, "App revision does not match the release commit")

    actual_extensions = {p.name for p in (app / "PlugIns").glob("*.appex")}
    require(actual_extensions == EXTENSIONS.keys(),
            f"Unexpected extension inventory: expected {sorted(EXTENSIONS)}, found {sorted(actual_extensions)}")
    bundles = [(app, "com.logseq.logseq", None)]
    bundles.extend((app / "PlugIns" / name, *expected) for name, expected in EXTENSIONS.items())

    app_intents = read_intents(app, APP_ACTIONS)
    shortcuts = {shortcut["actionIdentifier"] for shortcut in app_intents.get("autoShortcuts", [])}
    require(APP_ACTIONS <= shortcuts, f"Missing registered App Shortcuts: {sorted(APP_ACTIONS - shortcuts)}")
    home_shortcuts = {item["UIApplicationShortcutItemType"] for item in info.get("UIApplicationShortcutItems", [])}
    require({"logseq://audio", "logseq://capture"} <= home_shortcuts, "Missing home screen quick actions")
    widget = app / "PlugIns/LogseqWidgets.appex"
    read_intents(widget, WIDGET_ACTIONS)
    widget_binary = widget / read_info(widget)["CFBundleExecutable"]
    widget_data = widget_binary.read_bytes()
    missing_kinds = {kind for kind in WIDGET_KINDS if kind.encode() not in widget_data}
    require(not missing_kinds, f"Missing widget/control registrations: {sorted(missing_kinds)}")

    components = []
    for bundle, identifier, extension_point in bundles:
        bundle_info = read_info(bundle)
        require(bundle_info.get("CFBundleIdentifier") == identifier, f"Wrong bundle identifier: {bundle.name}")
        require(bundle_info.get("CFBundleShortVersionString") == version, f"Version mismatch: {bundle.name}")
        require(bundle_info.get("CFBundleVersion") == build, f"Build number mismatch: {bundle.name}")
        require(bundle_info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], f"Not an iOS device bundle: {bundle.name}")
        if extension_point:
            require(bundle_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == extension_point,
                    f"Wrong extension point: {bundle.name}")
        binary = bundle / bundle_info["CFBundleExecutable"]
        require(binary.is_file() and os.access(binary, os.X_OK), f"Missing executable: {bundle.name}")
        archs = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).split()
        require("arm64" in archs and not {"x86_64", "i386"}.intersection(archs), f"Wrong device architectures: {bundle.name}: {archs}")
        entitlements = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.PIPE))
        require(entitlements.get("com.apple.developer.team-identifier") == TEAM, f"Wrong signing team: {bundle.name}")
        require(APP_GROUP in entitlements.get("com.apple.security.application-groups", []), f"Missing shared App Group: {bundle.name}")
        if args.app_store:
            require(not entitlements.get("get-task-allow", False), f"Development entitlement in release: {bundle.name}")
            profile_path = bundle / "embedded.mobileprovision"
            require(profile_path.is_file(), f"Missing provisioning profile: {bundle.name}")
            profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile_path)], stderr=subprocess.PIPE))
            require(TEAM in profile.get("TeamIdentifier", []), f"Wrong provisioning team: {bundle.name}")
            require(profile["Entitlements"]["application-identifier"].endswith("." + identifier), f"Wrong provisioning App ID: {bundle.name}")
            require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"), f"Not an App Store profile: {bundle.name}")
            expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
            require(expires > datetime.datetime.now(datetime.timezone.utc), f"Expired provisioning profile: {bundle.name}")
        subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
        components.append({"bundle": bundle.name, "identifier": identifier, "extension_point": extension_point, "architectures": archs})
        print(f"Verified {bundle.name}: {identifier}, version {version} ({build}), team {TEAM}")

    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run([sys.executable, str(Path(__file__).with_name("verify-ios-native-symbols.py")), str(app)], check=True)
    return {"version": version, "build": build, "revision": info.get("LogseqRevision"),
            "components": components, "app_shortcuts": sorted(shortcuts), "widget_kinds": sorted(WIDGET_KINDS)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="Signed .app directory or exported .ipa")
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--revision")
    parser.add_argument("--app-store", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.bundle.suffix == ".ipa":
        with tempfile.TemporaryDirectory(prefix="logseq-release-verify-") as directory:
            subprocess.run(["ditto", "-x", "-k", str(args.bundle.resolve()), directory], check=True)
            apps = list((Path(directory) / "Payload").glob("*.app"))
            require(len(apps) == 1, f"Expected one app in IPA, found {len(apps)}")
            report = verify_app(apps[0], args)
    else:
        report = verify_app(args.bundle, args)
    report["source"] = str(args.bundle)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print("Verified complete release: app, two widgets, two controls, four App Shortcuts, share extension and native core")


if __name__ == "__main__":
    main()
