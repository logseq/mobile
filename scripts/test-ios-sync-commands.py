#!/usr/bin/env python3
"""Check native socket command execution against a real WebSocket without XCTest."""
import base64
import hashlib
import http.server
import pathlib
import struct
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SocketServer(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_args):
        pass

    def do_GET(self):
        assert self.headers.get("Authorization") == "Bearer test-token"
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        header = self.rfile.read(2)
        length = header[1] & 127
        if length == 126:
            length = struct.unpack("!H", self.rfile.read(2))[0]
        mask = self.rfile.read(4)
        data = self.rfile.read(length)
        assert bytes(value ^ mask[index % 4] for index, value in enumerate(data)) == b"opaque outbound body"
        body = b"opaque wire payload"
        self.wfile.write(bytes([0x81, len(body)]) + body)
        self.wfile.flush()
        self.server.received.set()
        self.rfile.read(2)


def main():
    build = ["swift", "build", "--package-path", str(ROOT / "apple"), "--disable-sandbox"]
    subprocess.run(build + ["--product", "LogseqModel"], check=True)
    output = pathlib.Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="logseq-sync-command-check-") as directory:
        executable = pathlib.Path(directory) / "check"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(output / "Modules"),
                        "-I", str(output / "LogseqCoreABI.build"), "-L", str(output), "-lLogseqModel",
                        "-Xlinker", "-rpath", "-Xlinker", str(output),
                        str(ROOT / "apple/Tests/UI/sync-command-execution.swift"), "-o", str(executable)], check=True)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SocketServer)
        server.daemon_threads = True
        server.received = threading.Event()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run([str(executable), f"ws://127.0.0.1:{server.server_port}/sync/plain-1"], check=True, timeout=15)
            assert server.received.is_set(), "The native transport did not send the core command"
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
