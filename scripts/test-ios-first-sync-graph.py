#!/usr/bin/env python3
"""Check first-graph cold launch against an isolated HTTP server, without XCTest."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


class CreationServer(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, body))
        # Stop before initial snapshot upload; reaching this endpoint proves
        # startup used the stored server without a selected graph or login.
        result = b'{"error":"self-hosted-creation-reached"}'
        self.send_response(409)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(result)))
        self.end_headers()
        self.wfile.write(result)


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CreationServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="logseq-first-graph-") as directory:
            source = Path(directory) / "first-sync-graph.swift"
            source.write_text((ROOT / "apple/Tests/UI/first-sync-graph.swift").read_text().replace(
                "__SELF_HOSTED_BASE_URL__", f"http://127.0.0.1:{server.server_port}"))
            subprocess.run([
                "python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                str(source), "FirstSyncGraphCheck",
            ], cwd=ROOT, check=True)
        assert len(CreationServer.requests) == 1, CreationServer.requests
        path, body = CreationServer.requests[0]
        assert path == "/graphs", path
        assert body["graph-name"] == "First self-hosted graph", body
        assert body["graph-e2ee?"] is False, body
        print("PASS: first graph creation reached only the configured self-hosted endpoint")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
