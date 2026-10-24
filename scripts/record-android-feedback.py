#!/usr/bin/env python3
"""Record real native scenarios in one parameterized instrumentation session."""
import argparse
import http.server
from pathlib import Path
import shutil
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("phase", choices=["before", "after"])
parser.add_argument("scenarios", nargs="+")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = root / "docs/qa/android-feedback" / args.phase
output.mkdir(parents=True, exist_ok=True)
failures, completed, requests = [], set(), []
server = None
catalog_args = []
if "responsiveness" in args.scenarios:
    class CatalogHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            time.sleep(5)
            body = b'{"graphs":[]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CatalogHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    subprocess.run(["adb", "reverse", f"tcp:{server.server_port}", f"tcp:{server.server_port}"], check=True)
    catalog_args = ["-e", "feedbackCatalogUrl", f"http://127.0.0.1:{server.server_port}"]

recorder = None
active = None
lines = []

def start(scenario):
    global recorder, active, lines
    active, lines = scenario, []
    subprocess.run(["adb", "shell", "rm", "-f", f"/sdcard/Android/data/com.logseq.app/files/feedback-{scenario}-*.png"], check=True)
    for old in output.glob(f"feedback-{scenario}-*.png"):
        old.unlink()
    remote = f"/sdcard/feedback-{args.phase}-{scenario}.mp4"
    recorder = subprocess.Popen(["adb", "shell", "screenrecord", "--bit-rate", "2000000", remote], stdout=subprocess.DEVNULL)

def finish(succeeded):
    global recorder, active
    if active is None:
        return
    scenario = active
    remote = f"/sdcard/feedback-{args.phase}-{scenario}.mp4"
    subprocess.run(["adb", "shell", "pkill", "-INT", "-f", "^screenrecord --bit-rate 2000000 " + remote], check=False)
    try:
        recorder.wait(timeout=10)
    except subprocess.TimeoutExpired:
        recorder.terminate(); recorder.wait(timeout=5)
    subprocess.run(["adb", "pull", remote, str(output / f"{scenario}.mp4")], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["adb", "shell", "rm", remote], check=True)
    files = subprocess.run(["adb", "shell", "ls", f"/sdcard/Android/data/com.logseq.app/files/feedback-{scenario}-*.png"], capture_output=True, text=True)
    for file in files.stdout.splitlines():
        if file.startswith("/sdcard/"):
            subprocess.run(["adb", "pull", file, str(output / Path(file).name)], check=True, stdout=subprocess.DEVNULL)
    captured = list(output.glob(f"feedback-{scenario}-*.png"))
    if captured:
        latest = max(captured, key=lambda path: int(path.stem.rsplit("-", 1)[1]))
        shutil.copy2(latest, output / f"{scenario}.png")
    log = "".join(lines) + f"\nFEEDBACK_SUCCESS={succeeded}\n"
    if scenario == "responsiveness":
        log += "CATALOG_REQUESTS=" + str(requests) + "\n"
        succeeded = succeeded and bool(requests)
    (output / f"{scenario}.log").write_text(log)
    completed.add(scenario)
    if not succeeded:
        failures.append(scenario)
    print("Recorded", args.phase, scenario, "PASS" if succeeded else "FAIL", flush=True)
    active = recorder = None

command = ["adb", "shell", "am", "instrument", "-w", "-r", "-e", "class",
    "com.logseq.app.AndroidFeedbackRecordingTest", "-e", "feedbackScenarios", ",".join(args.scenarios),
    "-e", "feedbackPhase", args.phase, *catalog_args,
    "com.logseq.app.test/androidx.test.runner.AndroidJUnitRunner"]
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
status = {}
all_lines = []
try:
    for line in process.stdout:
        all_lines.append(line)
        if active:
            lines.append(line)
        if line.startswith("INSTRUMENTATION_STATUS: "):
            key, _, value = line.removeprefix("INSTRUMENTATION_STATUS: ").strip().partition("=")
            status[key] = value
        elif line.startswith("INSTRUMENTATION_STATUS_CODE:"):
            if "feedback-start" in status:
                start(status["feedback-start"])
            elif "feedback-end" in status:
                finish(status.get("feedback-success") == "true")
            status = {}
    process.wait(timeout=10)
finally:
    (output / "android-instrumentation.log").write_text("".join(all_lines))
    finish(False)
    if process.poll() is None:
        process.terminate()
    if server:
        subprocess.run(["adb", "reverse", "--remove", f"tcp:{server.server_port}"], check=True)
        server.shutdown(); server.server_close()
missing = set(args.scenarios) - completed
if failures or missing:
    raise SystemExit("Failed scenarios: " + ", ".join(failures + sorted(missing)))
