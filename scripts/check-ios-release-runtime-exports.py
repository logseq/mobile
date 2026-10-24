#!/usr/bin/env python3
"""Check that a launch benchmark preserves the shipping executable's exports."""
from pathlib import Path
import subprocess
import sys

binary = Path(sys.argv[1])
if binary.is_dir():
    binary = binary / "RuntimeCheck"
expected = {
    "_logseq_https_send",
    "_logseq_https_upload_file",
    "_logseq_crypto_call",
    "_logseq_metric_log",
    "_logseq_graph_import_progress",
}
symbols = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
actual = {line.split()[-1] for line in symbols.splitlines() if line.strip()}
assert actual == expected, (
    f"Release benchmark exports differ from the shipping app: "
    f"{len(actual - expected)} unexpected, {len(expected - actual)} missing"
)
print("PASS: release benchmark exports match the shipping app's five FFI symbols")
