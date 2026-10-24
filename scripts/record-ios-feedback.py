#!/usr/bin/env python3
"""Record identical offline scenarios using the actual iOS core and native renderer."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import http.server
import threading

parser = argparse.ArgumentParser()
parser.add_argument("phase", choices=["before", "after"])
parser.add_argument("simulator")
parser.add_argument("scenarios", nargs="+")
parser.add_argument("--build-root", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = args.build_root.resolve() if args.build_root else root
out = root / "docs/qa/android-feedback" / args.phase
out.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["LOGSEQ_IOS_SIMULATOR"] = args.simulator
live_app_ready = False
for scenario in args.scenarios:
    server = None
    requests = []
    if scenario == "responsiveness":
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
        env["LOGSEQ_FEEDBACK_CATALOG_URL"] = f"http://127.0.0.1:{server.server_port}"
    else:
        env.pop("LOGSEQ_FEEDBACK_CATALOG_URL", None)
    env["LOGSEQ_FEEDBACK_SCENARIO"] = scenario
    math = scenario == "latex-1466"
    source = "feedback-math.swift" if math else "feedback-mobile.swift"
    shutil.copy2(root / "apple/Tests/UI" / source, build / "apple/Tests/UI" / source) if build != root else None
    fixture = build / ("_build/feedback-empty" if math else "_build/feedback-graph")
    fixture.mkdir(parents=True, exist_ok=True)
    if not math and not (fixture / "graphs/feedback/graph.sqlite").exists():
        shutil.copytree(root / "android/app/src/androidTest/assets/feedback", fixture / "graphs/feedback", dirs_exist_ok=True)
    log_path = out / f"ios-{scenario}.log"
    if not math and live_app_ready:
        subprocess.run(["xcrun", "simctl", "terminate", args.simulator, "com.logseq.logseq.PageBenchmark"], capture_output=True)
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator,
            "com.logseq.logseq.PageBenchmark", "data"], text=True).strip())
        documents = container / "Documents"
        shutil.rmtree(documents)
        shutil.copytree(fixture, documents)
        launch_env = env.copy()
        for name, value in env.items():
            if name.startswith("LOGSEQ_"):
                launch_env["SIMCTL_CHILD_" + name] = value
        with log_path.open("w") as log:
            subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator,
                "com.logseq.logseq.PageBenchmark"], env=launch_env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    else:
        with log_path.open("w") as log:
            subprocess.run(["python3", str(build / "apple/Tests/UI/run-simulator-runtime-check.py"),
                            str(build / "apple/Tests/UI" / source), "--interactive", str(fixture)],
                           env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
        live_app_ready = not math
    recorder = subprocess.Popen(["xcrun", "simctl", "io", args.simulator, "recordVideo", "--codec=h264", "--force", str(out / f"ios-{scenario}.mp4")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if math and args.phase == "before":
            time.sleep(8)
        else:
            container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator,
                "com.logseq.logseq.PageBenchmark", "data"], text=True).strip())
            result_file = container / "Documents/feedback-result.json"
            deadline = time.monotonic() + 55
            while not result_file.exists() and time.monotonic() < deadline:
                time.sleep(.3)
            if not result_file.exists():
                raise RuntimeError("Scenario did not complete: " + scenario)
            result = json.loads(result_file.read_text())
            if server:
                result["catalog-requests"] = requests
                if not requests:
                    raise RuntimeError("No catalog request reached the delayed test server")
            (out / f"ios-{scenario}.json").write_text(json.dumps(result, indent=2))
            imported = container / "Documents/feedback-import.json"
            if imported.exists():
                shutil.copy2(imported, out / f"ios-{scenario}-import.json")
            for screenshot in (container / "Documents").glob("feedback-*.png"):
                shutil.copy2(screenshot, out / ("ios-" + screenshot.name))
            if "failure" in result:
                raise RuntimeError(str(result))
            if args.phase == "after" and not all(result["observations"].values()):
                raise RuntimeError(str(result))
            time.sleep(2)
        subprocess.run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(out / f"ios-{scenario}.png")], check=True)
    finally:
        recorder.send_signal(signal.SIGINT)
        recorder.communicate(timeout=20)
        if server:
            server.shutdown(); server.server_close()
    print("Recorded", args.phase, scenario, flush=True)
