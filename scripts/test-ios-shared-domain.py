#!/usr/bin/env python3
"""Exercise shared domain rules through the native core and a fresh local graph."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


class GraphServer(http.server.BaseHTTPRequestHandler):
    graph = {"graph-id": "native-domain", "graph-name": "Native domain",
             "graph-e2ee?": False, "graph-ready-for-use?": True, "schema-version": "65.33"}
    snapshot = None

    def log_message(self, *_args):
        pass

    def respond(self, status, value):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        if "/snapshot/upload?" in self.path:
            type(self).snapshot = raw
            self.respond(200, {})
        elif self.path == "/graphs":
            self.respond(201, self.graph)
        else:
            self.respond(404, {})

    def do_GET(self):
        if self.path == "/graphs":
            self.respond(200, {"graphs": [self.graph]})
        elif "/pull?" in self.path:
            self.respond(200, {"type": "pull/ok", "t": 0})
        elif self.path.endswith("/snapshot/download"):
            self.respond(200, {"ok": True, "url": "/snapshot", "schema-version": "65.33", "t": 0})
        elif self.path == "/snapshot" and self.snapshot is not None:
            self.respond(200, self.snapshot)
        else:
            self.respond(404, {})


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GraphServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="logseq-shared-domain-") as directory:
            source = Path(directory) / "check.swift"
            source.write_text((ROOT / "apple/Tests/UI/shared-domain.swift").read_text().replace(
                "__SELF_HOSTED_BASE_URL__", f"http://127.0.0.1:{server.server_port}"))
            subprocess.run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                            str(source), "SharedDomainCheck"], cwd=ROOT, check=True)
        assert GraphServer.snapshot is not None, "The real core must generate its initial graph"
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
