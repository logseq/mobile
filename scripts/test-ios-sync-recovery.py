#!/usr/bin/env python3
"""Check peer-close recovery and transport/owner cancellation against real WebSockets."""
import argparse
import os
import base64
import hashlib
import http.server
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]

class Server(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_args): pass
    def do_GET(self):
        try:
            self.handle_websocket()
        except (BrokenPipeError, ConnectionResetError):
            # Transport-cancellation cases can disconnect during the handshake.
            self.close_connection = True

    def handle_websocket(self):
        if self.path == "/transport-cancel-connecting":
            time.sleep(1)
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        header = self.rfile.read(2)
        if len(header) != 2:
            self.close_connection = True
            return
        length = header[1] & 127
        mask, data = self.rfile.read(4), self.rfile.read(length)
        assert bytes(value ^ mask[index % 4] for index, value in enumerate(data)) == b"subscribe"
        self.wfile.write(b"\x81\x02{}"); self.wfile.flush()
        mode = self.path.strip("/")
        if mode in ("cancel", "transport-cancel"):
            self.rfile.read(2)
            return
        time.sleep(0.1)
        if mode in ("1000", "1001"):
            body = struct.pack("!H", int(mode))
            self.wfile.write(bytes([0x88, len(body)]) + body); self.wfile.flush()
            self.rfile.read(2)
        else:
            self.connection.shutdown(socket.SHUT_RDWR)
        self.close_connection = True

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", action="store_true")
    parser.add_argument("--mode")
    options = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ([options.mode] if options.mode else ("1000", "1001", "abrupt", "cancel", "transport-cancel", "transport-cancel-connecting")):
            url = f"ws://127.0.0.1:{server.server_port}/{mode}"
            source = str(ROOT / "apple/Tests/UI/websocket-idle-recovery.swift")
            if options.simulator:
                environment = os.environ.copy()
                environment["SIMCTL_CHILD_LOGSEQ_TEST_SOCKET_URL"] = url
                environment["SIMCTL_CHILD_LOGSEQ_TEST_SOCKET_MODE"] = mode
                subprocess.run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                                source, "IdleRecoveryCheck"], env=environment, check=True)
            else:
                subprocess.run(["python3", str(ROOT / "scripts/test-swift-model-check.py"),
                                source, url, mode], check=True)
    finally:
        server.shutdown(); server.server_close()

if __name__ == "__main__":
    main()
