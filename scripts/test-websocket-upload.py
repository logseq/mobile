#!/usr/bin/env python3
"""Exercise graph uploads and disconnects over real native WebSocket connections."""
import base64
import hashlib
import http.server
import json
from pathlib import Path
import struct
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]


class Server(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def frame(self):
        head = self.rfile.read(2)
        if len(head) != 2 or head[0] & 15 != 1:
            return None
        length = head[1] & 127
        if length == 126:
            length = struct.unpack("!H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4)
        data = self.rfile.read(length)
        return bytes(value ^ mask[index % 4] for index, value in enumerate(data))

    def do_GET(self):
        try:
            key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers()
            assert self.frame() == b"subscribe"
            request = self.frame()
            if request is None:
                return
            assert json.loads(request)["type"] == "tx/batch"
            if self.path == "/disconnect":
                self.close_connection = True
                return
            response = {"type": "tx/reject", "reason": "stale", "t": 42} if self.path == "/reject" else {
                "type": "tx/batch/ok", "t-before": 41, "t": 42, "txs": []}
            body = json.dumps(response).encode()
            self.wfile.write(bytes([0x81, len(body)]) + body)
            self.wfile.flush()
            self.frame()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ("ack", "reject", "disconnect", "background"):
            subprocess.run(["python3", str(ROOT / "scripts/test-swift-model-check.py"),
                            str(ROOT / "apple/Tests/UI/websocket-upload.swift"),
                            f"ws://127.0.0.1:{server.server_port}/{mode}", mode], check=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
