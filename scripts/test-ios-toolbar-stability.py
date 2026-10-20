#!/usr/bin/env python3
"""Replay real application patches in an iOS Release host and verify toolbar visibility."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
package = root / "_build/ios-toolbar-replay"
source = package / "Sources/ToolbarReplay"
source.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["LOGSEQ_TOOLBAR_REPLAY_OUTPUT"] = str(source / "stages.json")
subprocess.run(["dune", "exec", "--root", str(root), "shared/test/test_main.exe", "--", "test", "app"],
               cwd=root / "shared/test", env=env, check=True)
(package / "Package.swift").write_text(f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ToolbarReplay", platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [.package(path: "{root / 'apple'}")],
    targets: [.executableTarget(name: "ToolbarReplay", dependencies: [
        .product(name: "Logseq", package: "apple")
    ], resources: [.process("stages.json")])])
''')
(source / "ToolbarReplayApp.swift").write_bytes((root / "tests/apple-toolbar-replay/main.swift").read_bytes())
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
scratch = root / "apple/.build/toolbar-replay"
subprocess.run(["swift", "build", "--disable-sandbox", "--package-path", str(package),
    "--scratch-path", str(scratch), "--configuration", "release", "--product", "ToolbarReplay",
    "--triple", "arm64-apple-ios17.0-simulator", "--sdk", sdk], check=True)
built = scratch / "arm64-apple-ios-simulator/release"
app = package / "ToolbarReplay.app"
if app.exists():
    shutil.rmtree(app)
app.mkdir()
shutil.copy2(built / "ToolbarReplay", app / "ToolbarReplay")
for bundle in built.glob("*.bundle"):
    shutil.copytree(bundle, app / bundle.name)
(app / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.logseq.toolbar-replay", "CFBundleExecutable": "ToolbarReplay",
    "CFBundleName": "Toolbar Replay", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "LSRequiresIPhoneOS": True,
    "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "UIDeviceFamily": [1], "UILaunchScreen": {},
}))
subprocess.run([str(root / "scripts/compile-ios-app-assets.sh"), str(app), "iphonesimulator", "17.0"], check=True)
subprocess.run(["python3", str(root / "scripts/configure-ios-resource-bundles.py"), str(app)], check=True)
subprocess.run(["xcrun", "actool", "--compile", str(app / "logseq_Logseq.bundle"),
    "--platform", "iphonesimulator", "--minimum-deployment-target", "17.0", "--target-device", "iphone",
    str(root / "apple/Sources/Logseq/Resources/Icons.xcassets"),
    str(root / "apple/Sources/Logseq/Resources/Module.xcassets")], check=True, stdout=subprocess.DEVNULL)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
device = os.environ.get("LOGSEQ_IOS_SIMULATOR_UDID", "445958BA-3A69-4D8B-A57E-E019DC7F7D0E")
subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
flow = package / "toolbar-stability.yaml"
steps = ["appId: com.logseq.toolbar-replay", "---", "- launchApp:", "    clearState: true"]
for index, stage in enumerate(json.loads((source / "stages.json").read_text())):
    if index:
        steps += ['- tapOn:', '    id: "fixture.next"']
    steps += ['- extendedWaitUntil:', '    visible:', '      id: "fixture.phase.' + stage["name"] + '"',
              '    timeout: 10000', '- waitForAnimationToEnd',
              '- assertVisible:', '    id: "sync.connected"',
              '- assertVisible:', '    id: "button.connection"',
              '- takeScreenshot: "' + ('toolbar-' + stage['name']) + '"']
    if index == 0 or stage["name"] == "block":
        steps += ['- tapOn:', '    id: "button.connection"',
                  '- assertVisible: "Share"',
                  '- tapOn:', '    point: "50%,40%"']
flow.write_text("\n".join(steps) + "\n")
env["JAVA_HOME"] = "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
env["MAESTRO_CLI_NO_ANALYTICS"] = "1"
subprocess.run(["maestro", "--device", device, "test", "--debug-output", str(package / "maestro"), str(flow)],
               env=env, check=True)

# Accessibility can retain an overflowed action; verify the rendered pixels too.
run = max((package / "maestro/.maestro/tests").iterdir(), key=lambda p: p.stat().st_mtime)
for stage in json.loads((source / "stages.json").read_text()):
    screenshot = run / "toolbar-stability/takeScreenshot" / ("toolbar-" + stage["name"] + ".png")
    pixels = subprocess.check_output(["ffmpeg", "-loglevel", "error", "-i", str(screenshot),
        "-vf", "scale=402:-1,crop=132:64:270:54", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
    green = 0
    glyph_y = []
    for offset in range(0, len(pixels), 3):
        r, g, b = pixels[offset:offset + 3]
        x = (offset // 3) % 132
        y = (offset // 3) // 132
        if g > 90 and g > r * 1.3 and g > b * 1.1:
            green += 1
        if x > 74 and max(r, g, b) < 120:
            glyph_y.append(y)
    assert green >= 5, stage["name"] + ": sync indicator disappeared from the rendered toolbar"
    height = max(glyph_y) - min(glyph_y) + 1 if glyph_y else 0
    assert 2 <= height <= 14, stage["name"] + ": overflow glyph changed shape (height " + str(height) + ")"
    if stage["name"].startswith("page-") or stage["name"] == "back":
        full = subprocess.check_output(["ffmpeg", "-loglevel", "error", "-i", str(screenshot),
            "-vf", "scale=402:-1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
        # Measure rendered heading ink below the compact toolbar. An automatic
        # large-title navigation bar reserves an empty row and pushes this past 180pt.
        title_y = next((y for y in range(120, 300) if sum(
            max(full[(y * 402 + x) * 3:(y * 402 + x) * 3 + 3]) < 100
            for x in range(10, 380)) >= 5), None)
        assert title_y is not None and title_y <= 148, (
            stage["name"] + ": empty navigation title space pushes content to " + str(title_y) + "pt")
        print(stage["name"] + ": content heading begins at " + str(title_y) + "pt")
print("PASS: toolbar controls stay visible and content has no empty large-title row")
