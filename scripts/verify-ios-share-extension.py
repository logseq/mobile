#!/usr/bin/env python3
"""Verify that an assembled iOS app can receive text, images, and documents."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
extension = app / "PlugIns/LogseqShareExtension.appex"
assert extension.is_dir(), "The installed app must include its Share Extension"
host = plistlib.loads((app / "Info.plist").read_bytes())
info = plistlib.loads((extension / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"].startswith(host["CFBundleIdentifier"] + ".")
assert (extension / info["CFBundleExecutable"]).is_file()
assert info["CFBundleSupportedPlatforms"] == host["CFBundleSupportedPlatforms"]
assert info["CFBundleVersion"] == host["CFBundleVersion"]
assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.share-services"
rules = info["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"]
assert rules["NSExtensionActivationSupportsText"] is True
for kind in ("Image", "File"):
    assert rules[f"NSExtensionActivationSupports{kind}WithMaxCount"] >= 1
for bundle in (app, extension):
    signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(signed.stdout)
    assert all("*" not in group for group in entitlements.get("keychain-access-groups", [])), (
        f"{bundle.name} must request concrete keychain groups, not provisioning-profile wildcards"
    )
    assert "group.com.logseq.logseq" in entitlements.get("com.apple.security.application-groups", []), (
        f"{bundle.name} must share the capture inbox app group"
    )
print("Verified embedded Share Extension for text, photos, screenshots, PDF and Markdown files")
