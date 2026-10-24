#!/usr/bin/env python3
"""Measure fresh processes of one installed Release binary on an iOS simulator."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import plistlib
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.logseq.logseq.ColdStartBenchmark"


def require_production_modules():
    description = ROOT / "apple/.build/arm64-apple-ios-simulator/release/description.json"
    if not description.exists():
        raise SystemExit("Build the current Release simulator app before benchmarking")
    commands = {command["moduleName"]: command
                for command in json.loads(description.read_text())["swiftCommands"].values()}
    for name in ("Logseq", "LogseqModel", "LUIAppleBackend"):
        command = commands.get(name)
        arguments = command.get("otherArguments", []) if command else []
        if "-O" not in arguments or "-enable-testing" in arguments or "-DDEBUG" in arguments:
            raise SystemExit(f"{name} must be built with Release optimization and without testability")
    print("PASS: native UI modules use production Release flags without testability", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path, help="Isolated Documents fixture containing logseq.sqlite and graphs/")
    parser.add_argument("--graph-id", required=True)
    parser.add_argument("--simulator", default="booted")
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--maximum-ms", type=float, default=300)
    parser.add_argument("--minimum-rows", type=int, default=1)
    parser.add_argument("--cpu-times", action="store_true", help="Record diagnostic process and main-thread CPU counters at every stage")
    parser.add_argument("--app-entry", action="store_true", help="Run the actual AppMain and authentication restoration with an isolated synthetic stored session")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.iterations < 1 or args.minimum_rows < 1:
        parser.error("Iterations and minimum rows must be positive")
    require_production_modules()
    if any(os.environ.get(name) for name in ("DYLD_INSERT_LIBRARIES", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES")):
        raise SystemExit("Remove injected profiling libraries before production timing")
    args.output.mkdir(parents=True, exist_ok=True)
    bundle = "com.logseq.logseq.ColdStartAppEntry" if args.app_entry else BUNDLE
    entry = "app-entry-cold-start-benchmark.swift" if args.app_entry else "cold-start-benchmark.swift"
    env = os.environ.copy()
    env.update(LOGSEQ_IOS_CONFIGURATION="release", LOGSEQ_IOS_SIMULATOR=args.simulator,
               LOGSEQ_BENCH_GRAPH_ID=args.graph_id, LOGSEQ_IOS_BENCHMARK_BUNDLE_ID=bundle)
    subprocess.run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                    str(ROOT / "apple/Tests/UI" / entry),
                    "--prepare-benchmark", str(args.fixture.resolve())], cwd=ROOT, env=env, check=True)
    env["SIMCTL_CHILD_LOGSEQ_BENCH_GRAPH_ID"] = args.graph_id
    env["SIMCTL_CHILD_LOGSEQ_BENCH_CPU"] = "1" if args.cpu_times else "0"
    env.pop("SIMCTL_CHILD_LOGSEQ_BENCH_PREPARE_SESSION", None)
    if args.app_entry:
        # Seed once outside timed launches. This bundle has its own keychain
        # entitlement and rejects shared-capture directories outside its home.
        preparation = subprocess.run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                                      args.simulator, bundle],
                                     env={**env, "SIMCTL_CHILD_LOGSEQ_BENCH_PREPARE_SESSION": "1"},
                                     capture_output=True, text=True, timeout=30)
        (args.output / "session-preparation.log").write_text(preparation.stdout + preparation.stderr)
        if preparation.returncode or "COLD_START_SESSION_READY" not in preparation.stdout:
            raise SystemExit("Isolated session preparation failed; inspect session-preparation.log")
    installed = Path(subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", args.simulator, bundle, "app"], text=True).strip())
    executable = installed / plistlib.loads((installed / "Info.plist").read_bytes())["CFBundleExecutable"]
    binary_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    binary_stat = executable.stat()
    results = []
    for iteration in range(args.iterations):
        run = subprocess.run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                              args.simulator, bundle], env=env, capture_output=True, text=True, timeout=30)
        output = run.stdout + run.stderr
        (args.output / f"launch-{iteration + 1}.log").write_text(output)
        current_stat = executable.stat()
        if (current_stat.st_ino, current_stat.st_size, current_stat.st_mtime_ns) != (
                binary_stat.st_ino, binary_stat.st_size, binary_stat.st_mtime_ns):
            raise SystemExit("The installed benchmark binary changed during measurement")
        rows = [json.loads(line.removeprefix("COLD_START_RESULT ")) for line in output.splitlines()
                if line.startswith("COLD_START_RESULT ")]
        if run.returncode or len(rows) != 1:
            raise SystemExit(f"Launch {iteration + 1} failed; inspect its saved log")
        result = rows[0]
        if args.app_entry:
            authentication = re.findall(r"COLD_START_AUTH state=(\w+)", output)
            if len(authentication) != 1:
                raise SystemExit(f"Launch {iteration + 1} did not report the real authentication state")
            result["authentication_state"] = authentication[0]
        if args.cpu_times and (result.get("process_cpu_ms", 0) <= 0 or result.get("main_cpu_ms", 0) <= 0):
            raise SystemExit(f"Launch {iteration + 1} did not report valid diagnostic CPU counters")
        callbacks = re.findall(r"stage=first_display_after_commit process_ms=([\d.]+)", output)
        if len(callbacks) != 1 or result["process_ms"] < float(callbacks[0]):
            raise SystemExit(f"Launch {iteration + 1} reported a time before its display observation")
        if result["first_commit_ms"] > result["process_ms"]:
            raise SystemExit(f"Launch {iteration + 1} reported display before its frame commit")
        if result["nonempty_rows"] < args.minimum_rows:
            raise SystemExit(f"Launch {iteration + 1} did not present enough real journal content: {result}")
        results.append(result)
        print(f"Launch {iteration + 1}: {result}", flush=True)
    times = [result["process_ms"] for result in results]
    scope = ("actual AppMain, LogseqRootView and stored-session authentication restoration; synthetic unexpired credentials and offline API"
             if args.app_entry else "authenticated local journal renderer; authentication restoration/networking excluded")
    summary = {"scope": scope,
               "bundle_id": bundle, "binary_sha256": binary_hash,
               "diagnostic_cpu_counters": args.cpu_times,
               "cache": "fresh process; OS file cache and graph state retained between launches",
               "configuration": "Release without testability; exact shipping FFI exports; installed once",
               "endpoint": "display callback after a committed visible nonempty native outliner title",
               "rows": "visible native title labels at first frame commit",
               "samples": results, "median_ms": statistics.median(times), "maximum_ms": max(times),
               "threshold_ms": args.maximum_ms, "passed": max(times) <= args.maximum_ms}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    if not summary["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
