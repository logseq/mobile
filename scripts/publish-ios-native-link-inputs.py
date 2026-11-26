#!/usr/bin/env python3
"""Publish native link inputs while the caller holds the iOS build lock."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


def main():
    build_dir, runtime, https, crypto, threads, ffi = map(Path, sys.argv[1:])
    manifest = build_dir / "native-link-inputs.txt"
    snapshots = build_dir / "native-link-inputs"
    previous = manifest.read_text().strip().split(":", 1)[0] if manifest.exists() else ""

    fingerprint = hashlib.sha256()
    for path in (runtime, https, crypto, threads):
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        fingerprint.update(digest.digest())

    snapshot = snapshots / fingerprint.hexdigest()
    snapshot.mkdir(parents=True, exist_ok=True)
    link_runtime = snapshot / "logseq_runtime.o"
    inputs = ":".join(map(str, (link_runtime, https, crypto, threads, f"-L{ffi}")))
    with tempfile.TemporaryDirectory(dir=build_dir) as temporary:
        staging = Path(temporary)
        if not link_runtime.is_file():
            shutil.copyfile(runtime, staging / runtime.name)
            os.replace(staging / runtime.name, link_runtime)
        pending = staging / manifest.name
        pending.write_text(inputs + "\n")
        os.replace(pending, manifest)

    # Preserve the rollback snapshot across repeated builds of the same core.
    previous_snapshot = Path(previous).parent if previous else None
    old = sorted(
        (path for path in snapshots.iterdir()
         if path != snapshot and not path.is_symlink() and path.is_dir()
         and re.fullmatch(r"[0-9a-f]{64}", path.name)),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    rollback = previous_snapshot if previous_snapshot in old else next(iter(old), None)
    for path in old:
        if path != rollback:
            shutil.rmtree(path)
    print(inputs)


if __name__ == "__main__":
    main()
