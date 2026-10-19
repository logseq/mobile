#!/usr/bin/env python3
"""Verify the final executable exports every entry point looked up by OCaml."""
import plistlib
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
binary = app / info["CFBundleExecutable"]
exports = subprocess.check_output(["xcrun", "dyld_info", "-exports", str(binary)], text=True)
names = {line.split()[-1] for line in exports.splitlines() if line.split()}
required = {"_logseq_https_send", "_logseq_https_upload_file", "_logseq_crypto_call", "_logseq_metric_log", "_logseq_graph_import_progress"}
missing = required - names
if missing:
    raise SystemExit("Missing native runtime exports: " + ", ".join(sorted(missing)))
print("Verified native HTTP, upload, crypto and metric runtime exports")
