"""Run the continuous press-and-drag check against an installed iOS app."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile


def sdk_path(option):
    return Path(subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", option], text=True).strip())


def main():
    simulator, app_path, app_id, source, target = sys.argv[1:]
    developer = sdk_path("--show-sdk-platform-path") / "Developer"
    frameworks = developer / "Library/Frameworks"
    libraries = developer / "usr/lib"
    template = developer / "Library/Xcode/Agents/XCTRunner.app"
    test_source = Path(__file__).with_name("ios-outliner-drop.swift")
    suite = "OutlinerDropUITests"
    runner_id = "com.logseq.OutlinerDropUITests.xctrunner"

    with tempfile.TemporaryDirectory(prefix="logseq-outliner-drop-") as temp:
        directory = Path(temp)
        runner = directory / "XCTRunner.app"
        shutil.copytree(template, runner, symlinks=True)
        runner_info = runner / "Info.plist"
        info = plistlib.loads(runner_info.read_bytes())
        info.update(CFBundleExecutable="XCTRunner", CFBundleName=suite, CFBundleIdentifier=runner_id)
        runner_info.write_bytes(plistlib.dumps(info))
        bundle = runner / "PlugIns" / f"{suite}.xctest"
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": suite, "CFBundleIdentifier": "com.logseq.OutlinerDropUITests",
            "CFBundleName": suite, "CFBundlePackageType": "BNDL", "CFBundleVersion": "1",
        }))
        subprocess.run([
            "xcrun", "--sdk", "iphonesimulator", "swiftc",
            "-target", f"{platform.machine()}-apple-ios17.0-simulator",
            "-sdk", str(sdk_path("--show-sdk-path")),
            "-F", str(frameworks), "-I", str(libraries), "-L", str(libraries),
            "-emit-library", "-module-name", suite, "-o", str(bundle / suite), str(test_source),
        ], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
        subprocess.run([
            "codesign", "--force", "--sign", "-", "--entitlements", str(runner / "RunnerEntitlements.plist"), str(runner),
        ], check=True)
        configuration = directory / "outliner-drop.xctestrun"
        configuration.write_bytes(plistlib.dumps({
            "__xctestrun_metadata__": {"FormatVersion": 1},
            suite: {
                "BlueprintName": suite, "ProductModuleName": suite,
                "IsUITestBundle": True, "IsXCTRunnerHostedTestBundle": True,
                "TestBundlePath": f"__TESTHOST__/PlugIns/{suite}.xctest",
                "TestHostPath": str(runner), "TestHostBundleIdentifier": runner_id,
                "UITargetAppPath": str(Path(app_path).resolve()),
                "EnvironmentVariables": {
                    "LOGSEQ_DRAG_APP_ID": app_id,
                    "LOGSEQ_DRAG_SOURCE": source,
                    "LOGSEQ_DRAG_TARGET": target,
                },
                "TestingEnvironmentVariables": {
                    "DYLD_FRAMEWORK_PATH": str(frameworks),
                    "DYLD_LIBRARY_PATH": str(libraries),
                },
            },
        }))
        subprocess.run([
            "xcodebuild", "test-without-building", "-xctestrun", str(configuration),
            "-destination", f"platform=iOS Simulator,id={simulator}", "-parallel-testing-enabled", "NO",
        ], check=True)


if __name__ == "__main__":
    main()
