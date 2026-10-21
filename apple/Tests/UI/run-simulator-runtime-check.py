"""Link a Swift async check against the simulator app; never uses XCTest."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
CONFIGURATION = os.environ.get("LOGSEQ_IOS_CONFIGURATION", "debug")
if CONFIGURATION not in ("debug", "release"):
    raise SystemExit("LOGSEQ_IOS_CONFIGURATION must be debug or release")
BUILD = ROOT / "apple/.build/arm64-apple-ios-simulator" / CONFIGURATION
SIMULATOR = os.environ.get("LOGSEQ_IOS_SIMULATOR", "booted")
BUNDLE = "com.logseq.logseq.RuntimeCheck"


def run(arguments, **kwargs):
    try:
        return subprocess.run(arguments, check=True, **kwargs)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Runtime check command failed (exit {error.returncode}): {arguments[0]}") from None


def main():
    print(f"RUNTIME_CHECK_CONFIGURATION={CONFIGURATION}", flush=True)
    entry, check_type = sys.argv[1:3]
    interactive = check_type == "--interactive"
    benchmark = check_type in ("--benchmark", "--interactive")
    fixture = Path(sys.argv[3]).resolve() if benchmark else None
    bundle = "com.logseq.logseq.PageBenchmark" if benchmark else BUNDLE
    with tempfile.TemporaryDirectory(prefix="logseq-runtime-check-") as temporary:
        directory = Path(temporary)
        source = directory / "check.swift"
        source.write_text(Path(entry).read_text() if benchmark else Path(entry).read_text().replace("@main", "", 1) + f"""
import SwiftUI
@main struct RuntimeCheckApplication: App {{
    var body: some Scene {{
        WindowGroup {{
            Text("Runtime check").task {{
                do {{
                    try await {check_type}.main()
                    print("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                }} catch {{
                    print("RUNTIME_CHECK_FAILED: \\(error)")
                    exit(1)
                }}
            }}
        }}
    }}
}}
""")
        app = directory / "RuntimeCheck.app"
        app.mkdir()
        objects = [line for line in (BUILD / "LogseqShell.product/Objects.LinkFileList").read_text().splitlines()
                   if "/LogseqShell.build/" not in line]
        testing = os.environ.get("LOGSEQ_SWIFT_UI_TEST_SUITE") == "1"
        testing_args = []
        if testing:
            objects += [str(path) for path in sorted((BUILD / "LogseqTests.build").glob("*.o"))]
            developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
            frameworks = developer / "Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
            testing_args = ["-F", str(frameworks), "-framework", "Testing",
                            "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
        core = ROOT / "_build/ios-core/simulator"
        entitlements = directory / "entitlements.plist"
        build_entitlements = plistlib.loads((core / "simulator-entitlements.plist").read_bytes())
        team = build_entitlements["application-identifier"].split(".", 1)[0]
        identifier = f"{team}.{bundle}"
        entitlements.write_bytes(plistlib.dumps({
            "application-identifier": identifier,
            "keychain-access-groups": [identifier],
        }))
        runtime = max(core.glob("native-link-inputs/*/logseq_runtime.o"), key=lambda path: path.stat().st_mtime)
        toolchain = ROOT / "_build/apple-toolchains/ios"
        optimization = ["-O"] if CONFIGURATION == "release" else []
        runtime_exports = ["-Xlinker", "-export_dynamic"]
        for symbol in ("_logseq_https_send", "_logseq_https_upload_file", "_logseq_crypto_call", "_logseq_metric_log", "_logseq_graph_import_progress"):
            runtime_exports += ["-Xlinker", "-u", "-Xlinker", symbol]
        if CONFIGURATION == "release":
            runtime_exports += ["-Xlinker", "-dead_strip"]
        run(["xcrun", "--sdk", "iphonesimulator", "swiftc", *optimization, "-parse-as-library", "-DLOGSEQ_LINKED_CORE",
             "-target", "arm64-apple-ios17.0-simulator", "-I", str(BUILD / "Modules"),
             "-I", str(BUILD / "LogseqCoreABI.build"), str(source), *objects, *testing_args, str(runtime),
             str(core / "logseq_https_darwin.o"), str(core / "logseq_crypto_darwin.o"),
             str(toolchain / "arm64-apple-ios17.0-simulator-5.5.0/lib/ocaml/libthreadsnat.a"),
             "-L" + str(toolchain / "libffi-arm64-apple-ios17.0-simulator/lib"),
             "-lffi", "-lsqlite3", "-lz", "-framework", "Security", *runtime_exports,
             "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
             "-Xlinker", str(entitlements), "-o", str(app / "RuntimeCheck")])
        privacy = {key: value for key, value in plistlib.loads((ROOT / "apple/App/Info.plist").read_bytes()).items()
                   if key.endswith("UsageDescription")}
        (app / "Info.plist").write_bytes(plistlib.dumps({
            **privacy,
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "RuntimeCheck",
            "CFBundleName": "Runtime check", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1], "UILaunchScreen": {},
        }))
        for resource in (ROOT / "apple/.build/Logseq.app").glob("*.bundle"):
            shutil.copytree(resource, app / resource.name)
        assets = ROOT / "apple/.build/Logseq.app/Assets.car"
        if assets.exists():
            shutil.copy2(assets, app / assets.name)
        run(["codesign", "--force", "--sign", "-", str(app)])
        subprocess.run(["xcrun", "simctl", "terminate", SIMULATOR, bundle], capture_output=True)
        run(["xcrun", "simctl", "install", SIMULATOR, str(app)])
        launch_environment = os.environ.copy()
        if benchmark:
            container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", SIMULATOR, bundle, "data"], text=True).strip())
            documents = container / "Documents"
            if documents.exists():
                shutil.rmtree(documents)
            shutil.copytree(fixture, documents)
            for name, value in os.environ.items():
                if name.startswith("LOGSEQ_"):
                    launch_environment["SIMCTL_CHILD_" + name] = value
            if not interactive:
                launch_environment["SIMCTL_CHILD_LOGSEQ_BENCH_EXIT"] = "1"
        if interactive:
            run(["xcrun", "simctl", "launch", "--terminate-running-process", SIMULATOR, bundle], env=launch_environment)
            print(f"INTERACTIVE_CHECK_READY bundle={bundle}", flush=True)
            return
        try:
            output = subprocess.run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                                     SIMULATOR, bundle], capture_output=True, text=True, timeout=180 if testing else (90 if benchmark else 30), env=launch_environment)
            print(output.stdout)
            print(output.stderr)
            if "RUNTIME_CHECK_COMPLETE" not in output.stdout:
                print(output.stderr, file=sys.stderr)
                raise SystemExit("Simulator runtime check did not complete")
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", SIMULATOR, bundle], capture_output=True)
            artifacts = os.environ.get("LOGSEQ_RUNTIME_CHECK_ARTIFACTS")
            if artifacts:
                container = Path(subprocess.check_output(
                    ["xcrun", "simctl", "get_app_container", SIMULATOR, bundle, "data"], text=True).strip())
                destination = Path(artifacts)
                destination.mkdir(parents=True, exist_ok=True)
                for screenshot in (container / "Documents").glob("*.png"):
                    shutil.copy2(screenshot, destination / screenshot.name)
            if not benchmark:
                run(["xcrun", "simctl", "uninstall", SIMULATOR, bundle])


if __name__ == "__main__":
    main()
