#!/usr/bin/env python3
"""Drop local upload connections and run the production Swift transport against db-sync."""
from pathlib import Path
import http.client
import http.server
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import urllib.request
import uuid

root = Path(__file__).resolve().parents[1]
server = os.environ.get("LOGSEQ_LIVE_BASE_URL", "http://127.0.0.1:8787")
token = os.environ["LOGSEQ_LIVE_TOKEN"]
request = urllib.request.Request(server + "/graphs", headers={"Authorization": "Bearer " + token})
# Use only graphs created by the mobile upload test runner.
catalog = json.load(urllib.request.urlopen(request))
graph = next(g for g in catalog["graphs"] if g.get("graph-name", "").startswith("mobile-asset-e2e-") and not g.get("graph-e2ee?"))
asset_path = "/assets/" + graph["graph-id"] + "/" + str(uuid.uuid4()) + ".png"
counts = {}
class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_PUT(self):
        scenario, path = self.path[1:].split("/", 1)
        counts[scenario] = counts.get(scenario, 0) + 1
        if scenario == "forbidden":
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True
            return
        if scenario in ["unavailable", "cancelled"] or (scenario == "interrupted" and counts[scenario] == 1):
            self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 1024))
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()
            return
        body = self.rfile.read(int(self.headers["Content-Length"]))
        connection = http.client.HTTPConnection("127.0.0.1", 8787)
        connection.request("PUT", "/" + path, body, dict(self.headers))
        response = connection.getresponse()
        data = response.read()
        if scenario == "lost-response" and counts[scenario] == 1:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        self.send_response(response.status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        connection.close()
proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
threading.Thread(target=proxy.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="logseq-upload-retry-") as tmp:
        tmp = Path(tmp)
        config = tmp / "config.json"
        config.write_text(json.dumps({"baseURL": "http://127.0.0.1:" + str(proxy.server_port),
            "serverURL": server, "assetPath": asset_path, "token": token}))
        config.chmod(0o600)
        build = root / "apple/.build/arm64-apple-macosx/debug"
        binary = tmp / "retry-check"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(build / "Modules"),
            "-I", str(build / "LogseqCoreABI.build"), "-L", str(build), "-lLogseqModel",
            "-Xlinker", "-rpath", "-Xlinker", str(build),
            str(root / "apple/Tests/UI/pending-upload-retry.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(config)], check=True)
        assert all(counts.get(s, 0) >= 2 for s in ["interrupted", "lost-response"]), counts
        assert counts["forbidden"] == 1, counts
        assert counts["unavailable"] == 3, counts
        assert counts["cancelled"] == 1, counts
        print("PASS: real db-sync recovered interrupted requests with stable asset identity", counts)
finally:
    proxy.shutdown()
