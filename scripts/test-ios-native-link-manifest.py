#!/usr/bin/env python3
"""Exercise native link manifests after development and archive preparation."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "scripts/build-mobile-ios-device.sh").read_text()
start = source.index("native_link_fingerprint=$(")
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
                       ocaml_lib=str(library), ffi_prefix=str(base / "ffi"))
            subprocess.run(["/bin/bash", "-c", "set -euo pipefail\n" + fragment],
                           env=env, check=True, capture_output=True, text=True)
            assert manifest.exists(), f"mode {inputs_only}: native link manifest was not published"
            inputs = manifest.read_text().split(":")
            assert Path(inputs[0]).read_bytes() == paths[0].read_bytes(), "manifest kept the obsolete core"
            assert inputs[1:4] == [str(path) for path in paths[1:]], "manifest kept obsolete bridge inputs"
            print(f"ok - inputs-only={inputs_only}, stale manifest={stale}")
