"""Link a Swift async check against the simulator app; never uses XCTest."""
import fcntl
import os
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
CONFIGURATION = os.environ.get("LOGSEQ_IOS_CONFIGURATION", "debug")
if CONFIGURATION not in ("debug", "release"):
    raise SystemExit("LOGSEQ_IOS_CONFIGURATION must be debug or release")
SWIFT_SCRATCH = Path(os.environ.get("LOGSEQ_IOS_SWIFT_SCRATCH_PATH", ROOT / "apple/.build"))
BUILD = SWIFT_SCRATCH / "arm64-apple-ios-simulator" / CONFIGURATION
SIMULATOR = os.environ.get("LOGSEQ_IOS_SIMULATOR", "booted")
BUNDLE = "com.logseq.logseq.RuntimeCheck"


def run(arguments, **kwargs):
    try:
        return subprocess.run(arguments, check=True, **kwargs)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Runtime check command failed (exit {error.returncode}): {arguments[0]}") from None


def terminate_app(simulator, bundle):
    try:
        subprocess.run(["xcrun", "simctl", "terminate", simulator, bundle], capture_output=True, timeout=5)
    except subprocess.TimeoutExpired:
        # A fresh simulator can stall when terminating a bundle that was never installed.
        pass


def launch_with_result_file(simulator, bundle, environment, timeout):
    # CoreSimulator can still be busy registering apps after the first install.
    command_timeout = max(60, timeout)
    try:
        container = Path(run(["xcrun", "simctl", "get_app_container", simulator, bundle, "data"],
                             capture_output=True, text=True, timeout=command_timeout).stdout.strip())
    except subprocess.TimeoutExpired:
        raise SystemExit(f"Simulator app container lookup timed out after {command_timeout} seconds") from None
    result_file = container / "Library/Caches/runtime-check-result.txt"
    result_file.unlink(missing_ok=True)
    try:
        run(["xcrun", "simctl", "launch", "--terminate-running-process", simulator, bundle],
            env=environment, timeout=command_timeout)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"Simulator app launch timed out after {command_timeout} seconds") from None
    deadline = time.monotonic() + timeout
    result = ""
    while time.monotonic() < deadline:
        result = result_file.read_text() if result_file.is_file() else ""
        if result == "RUNTIME_CHECK_COMPLETE":
            print(result, flush=True)
            return
        if result.startswith("RUNTIME_CHECK_FAILED"):
            raise SystemExit(result)
        time.sleep(0.2)
    raise SystemExit(f"Simulator runtime check did not finish within {timeout} seconds "
                     f"(last status: {result or 'app produced no status'})")


def main():
    print(f"RUNTIME_CHECK_CONFIGURATION={CONFIGURATION}", flush=True)
    entry, check_type = sys.argv[1:3]
    interactive = check_type == "--interactive"
    benchmark = check_type in ("--benchmark", "--interactive")
    boot_simulator = os.environ.get("LOGSEQ_RUNTIME_CHECK_BOOT_SIMULATOR") == "1"
    use_result_file = boot_simulator and not benchmark
    fixture = Path(sys.argv[3]).resolve() if benchmark else None
    bundle = "com.logseq.logseq.PageBenchmark" if benchmark else BUNDLE
    lock_path = ROOT / "_build/ios-core/.build-lock"
    with tempfile.TemporaryDirectory(prefix="logseq-runtime-check-") as temporary, lock_path.open("a") as build_lock:
        fcntl.flock(build_lock, fcntl.LOCK_SH)
        directory = Path(temporary)
        source = directory / "check.swift"
        result_report = """
        try? FileManager.default.createDirectory(at: URL.cachesDirectory, withIntermediateDirectories: true)
        try? message.write(to: URL.cachesDirectory.appendingPathComponent("runtime-check-result.txt"),
                           atomically: true, encoding: .utf8)""" if use_result_file else ""
        source.write_text(Path(entry).read_text() if benchmark else Path(entry).read_text().replace("@main", "", 1) + f"""
import SwiftUI
@main struct RuntimeCheckApplication: App {{
    var body: some Scene {{
        WindowGroup {{
            Text("Runtime check").task {{
                report("RUNTIME_CHECK_RUNNING")
                do {{
                    try await {check_type}.main()
                    report("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                }} catch {{
                    report("RUNTIME_CHECK_FAILED: \\(error)")
                    exit(1)
                }}
            }}
        }}
    }}

    private func report(_ message: String) {{{result_report}
        print(message)
    }}
}}
""")
        app = directory / "RuntimeCheck.app"
        app.mkdir()
        for suffix in (".json", ".sql"):
            fixture_file = Path(entry).with_suffix(suffix)
            if fixture_file.is_file():
                shutil.copy2(fixture_file, app / fixture_file.name)
        objects = [line for line in (BUILD / "LogseqShell.product/Objects.LinkFileList").read_text().splitlines()
                   if "/LogseqShell.build/" not in line]
        testing = os.environ.get("LOGSEQ_SWIFT_UI_TEST_SUITE") == "1"
        testing_args = []
        if testing:
            object_map = json.loads((BUILD / "LogseqTests.build/output-file-map.json").read_text())
            objects += sorted(value["object"] for source, value in object_map.items()
                              if source and "object" in value)
            developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
            frameworks = developer / "Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
            testing_args = ["-F", str(frameworks), "-framework", "Testing",
                            "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
        core = ROOT / "_build/ios-core/simulator"
        entitlements = directory / "entitlements.plist"
        build_entitlements = plistlib.loads((core / "simulator-entitlements.plist").read_bytes())
        team = build_entitlements["application-identifier"].split(".", 1)[0]
        identifier = f"{team}.{bundle}"
        legacy_keychain = os.environ.get("LOGSEQ_RUNTIME_CHECK_LEGACY_KEYCHAIN") == "1"
        entitlements.write_bytes(plistlib.dumps({
            "application-identifier": identifier,
            "keychain-access-groups": [f"{team}.*" if legacy_keychain else identifier],
        }))
        runtime = Path((core / "native-link-inputs.txt").read_text().split(":", 1)[0])
        if not runtime.is_file():
            raise SystemExit("The app build's native core object is missing; rebuild the simulator app")
        toolchain = ROOT / "_build/apple-toolchains/ios"
        optimization = ["-O"] if CONFIGURATION == "release" else []
        runtime_exports = ["-Xlinker", "-export_dynamic"]
        for symbol in ("_logseq_https_send", "_logseq_https_upload_file", "_logseq_crypto_call", "_logseq_metric_log", "_logseq_graph_import_progress"):
            runtime_exports += ["-Xlinker", "-u", "-Xlinker", symbol]
        if CONFIGURATION == "release":
            runtime_exports += ["-Xlinker", "-dead_strip"]
        sentry_args = []
        if any("/SentrySwift.build/" in path for path in objects):
            description = json.loads((BUILD / "description.json").read_text())
            sentry = next(command for command in description["swiftCommands"].values()
                          if command["moduleName"] == "SentrySwift")
            arguments = sentry["otherArguments"]
            sentry_args = [item for index, value in enumerate(arguments[:-1]) if value == "-Xcc"
                           for item in (value, arguments[index + 1])]
            sentry_args.append("-lc++")
        print("Linking the simulator runtime check", flush=True)
        run(["xcrun", "--sdk", "iphonesimulator", "swiftc", *optimization, "-parse-as-library", "-DLOGSEQ_LINKED_CORE",
             "-target", "arm64-apple-ios17.0-simulator", "-I", str(BUILD / "Modules"),
             "-I", str(BUILD / "LogseqCoreABI.build"),
             *sentry_args,
             str(source), *objects, *testing_args, str(runtime),
             str(core / "logseq_https_darwin.o"), str(core / "logseq_crypto_darwin.o"),
             str(toolchain / "arm64-apple-ios17.0-simulator-5.5.0/lib/ocaml/libthreadsnat.a"),
             "-L" + str(toolchain / "libffi-arm64-apple-ios17.0-simulator/lib"),
             "-lffi", "-lsqlite3", "-lz", "-framework", "Security", *runtime_exports,
             "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
             "-Xlinker", str(entitlements), "-o", str(app / "RuntimeCheck")])
        privacy = {key: value for key, value in plistlib.loads((ROOT / "apple/App/Info.plist").read_bytes()).items()
                   if key.endswith("UsageDescription")}
        source_app = ROOT / "apple/.build/Logseq.app"
        info = source_app / "Info.plist"
        if not info.is_file():
            info = ROOT / "apple/App/Info.plist"
        orientations = plistlib.loads(info.read_bytes()).get(
            "UISupportedInterfaceOrientations", ["UIInterfaceOrientationPortrait"])
        (app / "Info.plist").write_bytes(plistlib.dumps({
            **privacy,
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "RuntimeCheck",
            "CFBundleName": "Runtime check", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
            "UISupportedInterfaceOrientations": orientations,
            **({"NSSupportsLiveActivities": True, "CFBundleShortVersionString": "1.0"}
               if os.environ.get("LOGSEQ_RUNTIME_CHECK_WIDGETS") == "1" else {}),
        }))
        if os.environ.get("LOGSEQ_RUNTIME_CHECK_WIDGETS") == "1":
            widget = app / "PlugIns/LogseqWidgets.appex"
            shutil.copytree(ROOT / "apple/.build/Logseq.app/PlugIns/LogseqWidgets.appex", widget)
            info_path = widget / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update({"CFBundleIdentifier": bundle + ".shortcuts",
                         "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"})
            info_path.write_bytes(plistlib.dumps(info))
            run(["codesign", "--force", "--sign", "-", str(widget)])
        resource_dir = BUILD if os.environ.get("LOGSEQ_IOS_RUNTIME_CHECK_BUILD") == "1" else source_app
        for resource in resource_dir.glob("*.bundle"):
            shutil.copytree(resource, app / resource.name)
        assets = resource_dir / "Assets.car"
        if assets.exists():
            shutil.copy2(assets, app / assets.name)
        fcntl.flock(build_lock, fcntl.LOCK_UN)
        run(["codesign", "--force", "--sign", "-", str(app)])
        if boot_simulator:
            # Simulator startup can contend with the Swift compiler on CI.
            print("Waiting for the simulator to boot", flush=True)
            run(["xcrun", "simctl", "bootstatus", SIMULATOR, "-b"])
        else:
            terminate_app(SIMULATOR, bundle)
        print("Installing the simulator runtime check", flush=True)
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
            run(["xcrun", "simctl", "launch", SIMULATOR, bundle], env=launch_environment)
            print(f"INTERACTIVE_CHECK_READY bundle={bundle}", flush=True)
            return
        timeout = 180 if testing else (90 if benchmark else int(os.environ.get("LOGSEQ_RUNTIME_CHECK_TIMEOUT", "30")))
        try:
            print("Launching the simulator runtime check", flush=True)
            if use_result_file:
                # The app owns the result, even if the simulator's console disconnects.
                launch_with_result_file(SIMULATOR, bundle, launch_environment, timeout)
                return
            output = subprocess.run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process", SIMULATOR, bundle],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                    timeout=timeout, env=launch_environment)
            print(output.stdout, flush=True)
            if "RUNTIME_CHECK_COMPLETE" not in output.stdout:
                raise SystemExit("Simulator runtime check did not complete")
        except subprocess.TimeoutExpired as error:
            if error.stdout:
                print(error.stdout.decode(errors="replace"), flush=True)
            raise SystemExit(f"Simulator runtime check did not exit within {timeout} seconds") from None
        finally:
            terminate_app(SIMULATOR, bundle)
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
            if not benchmark and os.environ.get("LOGSEQ_RUNTIME_CHECK_KEEP_INSTALLED") != "1":
                run(["xcrun", "simctl", "uninstall", SIMULATOR, bundle])


if __name__ == "__main__":
    main()
