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
BUNDLE = os.environ.get("LOGSEQ_IOS_RUNTIME_CHECK_BUNDLE_ID", "com.logseq.logseq.RuntimeCheck")


def run(arguments, **kwargs):
    try:
        return subprocess.run(arguments, check=True, **kwargs)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Runtime check command failed (exit {error.returncode}): {arguments[0]}") from None


def main():
    print(f"RUNTIME_CHECK_CONFIGURATION={CONFIGURATION}", flush=True)
    entry, check_type = sys.argv[1:3]
    interactive = check_type == "--interactive"
    benchmark = check_type in ("--benchmark", "--interactive", "--prepare-benchmark")
    prepare = check_type == "--prepare-benchmark"
    fixture = Path(sys.argv[3]).resolve() if benchmark else None
    external_entry = Path(entry).name in ("app-entry-cold-start-benchmark.swift", "cold-start-visible-content.swift")
    app_entry = Path(entry).name == "app-entry-cold-start-benchmark.swift"
    common_source = (ROOT / "apple/Tests/UI/cold-start-benchmark.swift").read_text() if external_entry else ""
    if app_entry:
        # Retain the actual production App and delegate, replacing only @main
        # with the measurement trampoline in the benchmark entry.
        production_entry = (ROOT / "apple/App/Sources/Main.swift").read_text()
        if production_entry.count("@main struct AppMain") != 1:
            raise SystemExit("The production app entry changed; update the startup measurement trampoline")
        production_entry = production_entry.replace("@main struct AppMain", "struct AppMain", 1)
        for method, stage in (("onInit", "init"), ("onLaunch", "launch")):
            call = f"AppDelegate.shared.{method}()"
            if production_entry.count(call) != 1:
                raise SystemExit(f"The production {method} delegate changed; update startup stage observation")
            production_entry = production_entry.replace(call,
                f'Clock.mark("delegate_{stage}_begin"); {call}; Clock.mark("delegate_{stage}_end")')
        common_source += "\n" + production_entry + "\n" + (ROOT / "apple/App/Sources/QuickActions.swift").read_text()
    bundle = os.environ.get("LOGSEQ_IOS_BENCHMARK_BUNDLE_ID", "com.logseq.logseq.PageBenchmark") if benchmark else BUNDLE
    app_name = bundle.rsplit(".", 1)[-1] if bundle.startswith("com.logseq.logseq.ColdStart") else "RuntimeCheck"
    with tempfile.TemporaryDirectory(prefix="logseq-runtime-check-") as temporary:
        directory = Path(temporary)
        source = directory / "check.swift"
        source.write_text(common_source + (Path(entry).read_text() if benchmark else Path(entry).read_text().replace("@main", "", 1) + f"""
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
"""))
        app = directory / f"{app_name}.app"
        app.mkdir()
        fixture_json = Path(entry).with_suffix(".json")
        if fixture_json.exists():
            shutil.copy2(fixture_json, app / fixture_json.name)
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
        runtime = Path((core / "native-link-inputs.txt").read_text().split(":", 1)[0])
        if not runtime.is_file():
            raise SystemExit("The app build's native core object is missing; rebuild the simulator app")
        toolchain = ROOT / "_build/apple-toolchains/ios"
        optimization = ["-O"] if CONFIGURATION == "release" else []
        production_exports = CONFIGURATION == "release" and not testing
        runtime_exports = [] if production_exports else ["-Xlinker", "-export_dynamic"]
        for symbol in ("_logseq_https_send", "_logseq_https_upload_file", "_logseq_crypto_call", "_logseq_metric_log", "_logseq_graph_import_progress"):
            runtime_exports += ["-Xlinker", "-u", "-Xlinker", symbol]
            if production_exports:
                runtime_exports += ["-Xlinker", "-exported_symbol", "-Xlinker", symbol]
        if CONFIGURATION == "release":
            runtime_exports += ["-Xlinker", "-dead_strip"]
        entry_flags = ["-DLOGSEQ_BENCH_EXTERNAL_ENTRY"] if external_entry else []
        if app_entry:
            entry_flags += ["-DLOGSEQ_BENCH_APP_ENTRY"]
        run(["xcrun", "--sdk", "iphonesimulator", "swiftc", *optimization, *entry_flags, "-parse-as-library", "-DLOGSEQ_LINKED_CORE",
             "-target", "arm64-apple-ios17.0-simulator", "-I", str(BUILD / "Modules"),
             "-I", str(BUILD / "LogseqCoreABI.build"), str(source), *objects, *testing_args, str(runtime),
             str(core / "logseq_https_darwin.o"), str(core / "logseq_crypto_darwin.o"),
             str(toolchain / "arm64-apple-ios17.0-simulator-5.5.0/lib/ocaml/libthreadsnat.a"),
             "-L" + str(toolchain / "libffi-arm64-apple-ios17.0-simulator/lib"),
             "-lffi", "-lsqlite3", "-lz", "-framework", "Security", *runtime_exports,
             "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
             "-Xlinker", str(entitlements), "-o", str(app / app_name)])
        if production_exports:
            run(["python3", str(ROOT / "scripts/check-ios-release-runtime-exports.py"),
                 str(app / app_name)])
        privacy = {key: value for key, value in plistlib.loads((ROOT / "apple/App/Info.plist").read_bytes()).items()
                   if key.endswith("UsageDescription")}
        shipping_info = plistlib.loads((ROOT / "apple/App/Info.plist").read_bytes())
        launch_metadata = {key: shipping_info[key] for key in (
            "UILaunchScreen", "BGTaskSchedulerPermittedIdentifiers", "UIBackgroundModes", "UIApplicationShortcutItems"
        ) if key in shipping_info} if app_entry else {"UILaunchScreen": {}}
        (app / "Info.plist").write_bytes(plistlib.dumps({
            **privacy,
            **launch_metadata,
            "CFBundleIdentifier": bundle, "CFBundleExecutable": app_name,
            "CFBundleName": "Runtime check" if app_name == "RuntimeCheck" else app_name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1],
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
        if prepare:
            print(f"BENCHMARK_READY bundle={bundle}", flush=True)
            return
        if interactive:
            run(["xcrun", "simctl", "launch", "--terminate-running-process", SIMULATOR, bundle], env=launch_environment)
            print(f"INTERACTIVE_CHECK_READY bundle={bundle}", flush=True)
            return
        try:
            output = subprocess.run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                                     SIMULATOR, bundle], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                    timeout=180 if testing else (90 if benchmark else int(os.environ.get("LOGSEQ_RUNTIME_CHECK_TIMEOUT", "30"))), env=launch_environment)
            print(output.stdout)
            if "RUNTIME_CHECK_COMPLETE" not in output.stdout:
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
                for diagnostic in (container / "Library/Caches").glob("interaction-debug*.log"):
                    shutil.copy2(diagnostic, destination / diagnostic.name)
            if not benchmark:
                run(["xcrun", "simctl", "uninstall", SIMULATOR, bundle])


if __name__ == "__main__":
    main()
