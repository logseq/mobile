"""Measure the installed app without clearing its graph or authentication."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", default="emulator-5554")
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "rerun")
parser.add_argument("--variant", choices=["profile", "release"], default="release")
parser.add_argument("--runs", type=int, default=3)
options = parser.parse_args()
OUT = options.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
DEVICE = options.device
APP = "com.logseq.app"

def require_idle_host():
    processes = subprocess.check_output(["ps", "-axo", "command="], text=True)
    for command in processes.splitlines():
        executable = command.split(maxsplit=1)[0].rsplit("/", 1)[-1] if command.strip() else ""
        building = executable in {"xcodebuild", "swift-frontend", "swiftc", "clang", "clang++"}
        building |= executable == "dune" and "build" in command.split()
        building |= "GradleWrapperMain" in command
        recording = (executable == "adb" and "screenrecord" in command.split()) or "simctl io" in command and "recordVideo" in command
        if building or recording:
            reason = "host build" if building else "recording"
            raise SystemExit(f"Invalid sample: concurrent {reason}: {command}")

def adb(*args):
    require_idle_host()
    result = subprocess.check_output(["adb", "-s", DEVICE, *args], text=True)
    require_idle_host()
    return result

def snapshot(name):
    raw = adb("shell", "dumpsys", "gfxinfo", APP, "framestats")
    (OUT / f"{name}-gfxinfo.txt").write_text(raw)
    (OUT / f"{name}-meminfo.txt").write_text(adb("shell", "dumpsys", "meminfo", APP))
    result = {}
    for key, pattern in {
        "frames": r"Total frames rendered: (\d+)",
        "janky_frames": r"Janky frames: (\d+)",
        "p50_ms": r"50th percentile: (\d+)ms",
        "p95_ms": r"95th percentile: (\d+)ms",
        "p99_ms": r"99th percentile: (\d+)ms",
        "slow_ui_thread": r"Number Slow UI thread: (\d+)",
    }.items():
        match = re.search(pattern, raw)
        if match:
            result[key] = int(match[1])
    if result.get("frames"):
        result["jank_percent"] = round(result["janky_frames"] / result["frames"] * 100, 2)
    print(name, result, flush=True)
    return result

def reset():
    adb("shell", "dumpsys", "gfxinfo", APP, "reset")

def viewport(name):
    focus = adb("shell", "dumpsys", "window", "displays")
    (OUT / f"{name}-window.txt").write_text(focus)
    if not re.search(r"mCurrentFocus=.*\b" + re.escape(APP) + r"/", focus):
        raise SystemExit("Invalid sample: app is not in the foreground.")
    raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    (OUT / f"{name}-hierarchy.xml").write_text(raw)
    start, end = raw.find("<hierarchy"), raw.rfind("</hierarchy>")
    if start < 0 or end < 0:
        raise SystemExit("Invalid sample: missing UI hierarchy.")
    tree = ET.fromstring(raw[start:end + len("</hierarchy>")])
    if any((node.get("package") != APP and "isn't responding" in node.get("text", "").lower().replace("’", "'"))
           or node.get("package") == "android"
           for node in tree.iter("node")):
        raise SystemExit("Invalid sample: system dialog obstructs the app.")
    lists = [node for node in tree.iter("node") if node.get("resource-id") == "list.outliner"]
    if not lists:
        raise SystemExit("Invalid sample: expected journal list is not visible.")
    # Text/row identity changes establish movement even if the final return
    # gesture restores the initial viewport. Bounds also cover partial rows.
    return tuple((node.get("resource-id"), node.get("text"), node.get("bounds"))
                 for node in lists[0].iter("node") if node.get("text") or "outliner.block." in node.get("resource-id", ""))

results = {"device": DEVICE, "variant": options.variant, "launches": []}
for index in range(options.runs):
    adb("logcat", "-c")
    raw = adb("shell", "am", "start", "-W", "-S", "-n", APP + "/.MainActivity")
    time.sleep(3)
    logs = adb("logcat", "-d", "-v", "brief", "-s", "System.out", "AndroidRuntime")
    (OUT / f"launch-{index + 1}.log").write_text(raw + "\n" + logs)
    metrics = {key: float(value) for key, value in re.findall(r"LOGSEQ_LAUNCH_METRIC (\w+)_ms=([0-9.]+)", logs)}
    total = re.search(r"TotalTime: (\d+)", raw)
    if not total or "Status: ok" not in raw:
        raise SystemExit("Invalid launch sample: Activity Manager did not report a completed launch.")
    metrics["am_total_ms"] = int(total[1])
    results["launches"].append(metrics)
    print("launch", index + 1, metrics, flush=True)
    time.sleep(1)

reset()
time.sleep(10)
results["idle_10s"] = snapshot("idle-10s")

for repeat in range(3):
    before = viewport(f"scroll-{repeat + 1}-before")
    reset()
    middle = None
    for index in range(8):
        start, end = (1800, 600) if index < 4 else (600, 1800)
        adb("shell", "input", "swipe", "500", str(start), "500", str(end), "400")
        time.sleep(0.15)
        if index == 3:
            middle = viewport(f"scroll-{repeat + 1}-middle")
    time.sleep(1)
    results[f"scroll_{repeat + 1}"] = snapshot(f"scroll-{repeat + 1}")
    if not results[f"scroll_{repeat + 1}"].get("frames"):
        raise SystemExit("Invalid scrolling sample: no App frames. Check system dialogs and foreground state.")
    viewport(f"scroll-{repeat + 1}-after")
    if not before or middle == before:
        raise SystemExit("Invalid scrolling sample: no list movement.")

(OUT / "android-performance.json").write_text(json.dumps(results, indent=2) + "\n")
