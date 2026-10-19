#!/usr/bin/env python3
"""Exercise the Swift graph bootstrap against a real HTTP snapshot server, without XCTest."""
import argparse
import gzip
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = bytes([0, 0, 0, 3, 65, 66, 67])


class SnapshotServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer test-token":
            self.send_error(401)
            return
        _, _, graph_id, *route = urllib.parse.urlsplit(self.path).path.split("/")
        headers = {}
        if route == ["snapshot", "download"]:
            metadata = {"ok": True, "key": f"stream/{graph_id}.snapshot",
                        "url": f"/sync/{graph_id}/snapshot/stream"}
            if graph_id == "metadata-schema":
                metadata["schema-version"] = "65.33"
            if graph_id.endswith("gzip") and graph_id != "unadvertised-gzip":
                metadata["content-encoding"] = "gzip"
            body = json.dumps(metadata).encode()
        elif route == ["pull"]:
            cursor = -1 if graph_id == "invalid-cursor" else 48192
            body = json.dumps({"type": "pull/ok", "t": cursor, "txs": []}).encode()
        elif route == ["snapshot", "stream"]:
            body = gzip.compress(SNAPSHOT) if graph_id.endswith("gzip") else SNAPSHOT
            if graph_id == "nested-gzip":
                body = gzip.compress(body)
            elif graph_id == "decoded-gzip":
                body = SNAPSHOT
            elif graph_id == "corrupt-gzip":
                body = bytes([0x1F, 0x8B, 8, 0]) + b"truncated gzip stream"
            if graph_id != "missing-row-count":
                headers["x-snapshot-row-count"] = "1"
            if graph_id in ("transport-gzip", "nested-gzip"):
                headers["Content-Encoding"] = "gzip"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", help="Run the same HTTP checks in a booted iOS simulator")
    args = parser.parse_args()
    scratch = ROOT / ("apple/.build/snapshot-http-check-ios" if args.simulator
                      else "apple/.build/snapshot-http-check")
    build = ["swift", "build", "--package-path", str(ROOT / "apple"),
             "--scratch-path", str(scratch), "--disable-sandbox"]
    compiler_options = []
    if args.simulator:
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        triple = "arm64-apple-ios17.0-simulator"
        build += ["--triple", triple, "--sdk", sdk]
        compiler_options = ["-target", triple, "-sdk", sdk]
    subprocess.run(build + ["--product", "LogseqModel"], check=True)
    build_dir = pathlib.Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="logseq-snapshot-check-") as directory:
        executable = pathlib.Path(directory) / "check"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library"] + compiler_options + [
                        "-I", str(build_dir / "Modules"),
                        "-I", str(build_dir / "LogseqCoreABI.build"),
                        "-L", str(build_dir), "-lLogseqModel",
                        "-Xlinker", "-rpath", "-Xlinker", str(build_dir),
                        str(ROOT / "apple/Tests/UI/snapshot-download.swift"),
                        "-o", str(executable)], check=True)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SnapshotServer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            launch = ["xcrun", "simctl", "spawn", args.simulator] if args.simulator else []
            result = subprocess.run(launch + [str(executable), f"http://127.0.0.1:{server.server_port}"])
        finally:
            server.shutdown()
            server.server_close()
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
