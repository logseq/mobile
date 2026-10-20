#!/usr/bin/env python3
"""Run encrypted graph creation through native crypto and an isolated sync server."""
import base64
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


class EncryptionServer(http.server.BaseHTTPRequestHandler):
    user_keys = None
    graphs = []
    graph_keys = []
    key_uploads = 0
    graph_creates = 0

    def log_message(self, *_args):
        pass

    def respond(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        token = self.headers.get("Authorization")
        if self.path == "/e2ee/user-keys":
            if token == "Bearer fixture-denied":
                self.respond(403, {})
                return
            if token == "Bearer fixture-malformed":
                self.respond(200, {"public-key": "partial-key"})
                return
            self.respond(200, self.user_keys or {})
        elif self.path == "/graphs":
            self.respond(200, {"graphs": self.graphs})
        else:
            self.respond(404, {})

    def do_POST(self):
        token = self.headers.get("Authorization")
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        if "/snapshot/upload?" in self.path:
            self.respond(200, {})
            return
        body = json.loads(raw)
        state = type(self)
        if self.path == "/e2ee/user-keys":
            if token == "Bearer fixture-upload-failure":
                self.respond(503, {})
                return
            assert token == "Bearer fixture-token"
            assert state.user_keys is None, "Existing account keys must never be overwritten"
            state.user_keys = body
            state.key_uploads += 1
            self.respond(200, body)
        elif self.path == "/graphs":
            state.graph_creates += 1
            if body["graph-e2ee?"] and state.user_keys is None:
                self.respond(400, {"error": "missing user rsa key pair"})
                return
            graph = {"graph-id": f"graph-{len(state.graphs)}", "graph-name": body["graph-name"],
                     "graph-e2ee?": body["graph-e2ee?"], "graph-ready-for-use?": True}
            state.graphs.append(graph)
            self.respond(201, graph)
        elif self.path.startswith("/e2ee/graphs/"):
            state.graph_keys.append(body["encrypted-aes-key"])
            self.respond(200, body)
        else:
            self.respond(404, {})


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), EncryptionServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="logseq-encrypted-graph-") as directory:
            source = Path(directory) / "check.swift"
            source.write_text((ROOT / "apple/Tests/UI/encrypted-graph-setup.swift").read_text().replace(
                "__SELF_HOSTED_BASE_URL__", f"http://127.0.0.1:{server.server_port}"))
            subprocess.run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                            str(source), "EncryptedGraphSetupCheck"], check=True, cwd=ROOT)
        assert EncryptionServer.key_uploads == 1
        assert EncryptionServer.graph_creates == 3, "Password setup must precede graph creation"
        keys = EncryptionServer.user_keys
        public = json.loads(keys["public-key"])
        private = json.loads(keys["encrypted-private-key"])
        assert private[0] == "20251210"
        def binary(value):
            if isinstance(value, list):
                assert value[0] == "~#'" and len(value) == 2
                value = value[1]
            assert value.startswith("~b"), value
            return base64.b64decode(value[2:]).hex()
        payload = {"public": binary(public), "salt": binary(private[1]), "iv": binary(private[2]),
                   "private": binary(private[3]),
                   "graphs": [binary(json.loads(key)) for key in EncryptionServer.graph_keys]}
        # Import and decrypt with WebCrypto, independently of the native codec.
        check = """
import {webcrypto} from 'node:crypto';
let input = ''; for await (const chunk of process.stdin) input += chunk;
const p = JSON.parse(input), subtle = webcrypto.subtle;
const bytes = h => Buffer.from(h, 'hex');
const password = await subtle.importKey('raw', Buffer.from('correct horse battery staple'), 'PBKDF2', false, ['deriveKey']);
const derived = await subtle.deriveKey({name:'PBKDF2', salt:bytes(p.salt), iterations:600000, hash:'SHA-256'}, password, {name:'AES-GCM', length:256}, false, ['decrypt']);
const raw = await subtle.decrypt({name:'AES-GCM', iv:bytes(p.iv)}, derived, bytes(p.private));
const key = await subtle.importKey('pkcs8', raw, {name:'RSA-OAEP', hash:'SHA-256'}, false, ['decrypt']);
const pub = await subtle.importKey('spki', bytes(p.public), {name:'RSA-OAEP', hash:'SHA-256'}, false, ['encrypt']);
if (key.algorithm.modulusLength !== 4096) throw Error('Expected RSA-4096');
for (const encrypted of p.graphs) {
  const aes = await subtle.decrypt({name:'RSA-OAEP'}, key, bytes(encrypted));
  if (aes.byteLength !== 32) throw Error('Expected AES-256 graph key');
  const wrapped = await subtle.encrypt({name:'RSA-OAEP'}, pub, aes);
  await subtle.decrypt({name:'RSA-OAEP'}, key, wrapped);
}
console.log('PASS: WebCrypto imports the native account pair and decrypts both graph keys');
"""
        subprocess.run(["node", "--input-type=module", "-e", check], input=json.dumps(payload), text=True, check=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
