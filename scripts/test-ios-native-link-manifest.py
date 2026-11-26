#!/usr/bin/env python3
"""Exercise native link manifests after development and archive preparation."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "scripts/build-mobile-ios-device.sh").read_text()
start = source.index("native_link_inputs=$(python3 ")
end = source.index("\nprune_stale_swift_resource_bundles\n", start)
fragment = source[start:end]

for inputs_only in ("0", "1"):
    for stale in (False, True):
        with tempfile.TemporaryDirectory(prefix="logseq-native-manifest-") as directory:
            base = Path(directory)
            core = base / "device core"
            library = base / "ocaml lib"
            core.mkdir()
            library.mkdir()
            paths = [base / "runtime.o", core / "https.o", core / "crypto.o", library / "libthreadsnat.a"]
            for index, path in enumerate(paths):
                path.write_bytes(f"fresh native input {index}".encode())
            manifest = core / "native-link-inputs.txt"
            if stale:
                manifest.write_text("obsolete-runtime.o:obsolete-bridge.o")
            env = dict(os.environ, LOGSEQ_IOS_LINK_INPUTS_ONLY=inputs_only,
                       core_build_dir=str(core), core_object=str(paths[0]),
                       https_object=str(paths[1]), crypto_object=str(paths[2]),
                       ocaml_lib=str(library), ffi_prefix=str(base / "ffi"), repo_root=str(root))
            subprocess.run(["/bin/bash", "-c", "set -euo pipefail\n" + fragment],
                           env=env, check=True, capture_output=True, text=True)
            assert manifest.exists(), f"mode {inputs_only}: native link manifest was not published"
            inputs = manifest.read_text().strip().split(":")
            assert Path(inputs[0]).read_bytes() == paths[0].read_bytes(), "manifest kept the obsolete core"
            assert inputs[1:4] == [str(path) for path in paths[1:]], "manifest kept obsolete bridge inputs"
            print(f"ok - inputs-only={inputs_only}, stale manifest={stale}")

with tempfile.TemporaryDirectory(prefix="logseq-native-retention-") as directory:
    base = Path(directory)
    runtime, https, crypto, threads = (base / name for name in ("runtime.o", "https.o", "crypto.o", "threads.a"))
    for path in (runtime, https, crypto, threads):
        path.write_text(path.name)
    command = ["python3", root / "scripts/publish-ios-native-link-inputs.py",
               base, runtime, https, crypto, threads, base / "ffi"]
    previous = None
    for path in (runtime, https, crypto, threads):
        path.write_text(f"updated {path.name}")
        current = Path(subprocess.check_output(command, text=True).split(":", 1)[0])
        assert current != previous
        assert current.read_bytes() == runtime.read_bytes()
        snapshots = {current}
        if previous:
            snapshots.add(previous)
        assert set((base / "native-link-inputs").glob("*/logseq_runtime.o")) == snapshots
        assert subprocess.check_output(command, text=True).split(":", 1)[0] == str(current)
        assert set((base / "native-link-inputs").glob("*/logseq_runtime.o")) == snapshots
        previous = current
    print("ok - changes to each input invalidate the link, with at most two snapshots")
