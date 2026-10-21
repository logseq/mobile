#!/usr/bin/env python3
"""Exercise the production Android OCaml primitives under JNI allocation failures."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    java_home = os.environ.get("JAVA_HOME")
    if not java_home and sys.platform == "darwin":
        java_home = subprocess.check_output(["/usr/libexec/java_home"], text=True).strip()
    if not java_home:
        raise SystemExit("JAVA_HOME must identify a JDK with JNI headers")
    prefix = ["opam", "exec", "--switch=" + os.environ.get("LOGSEQ_OPAM_SWITCH", "5.5.0"), "--"]
    ocaml = subprocess.check_output(prefix + ["ocamlopt", "-where"], text=True).strip()
    includes = ["-I" + ocaml, "-I" + str(Path(java_home) / "include"),
                "-I" + str(Path(java_home) / "include" / ("darwin" if sys.platform == "darwin" else "linux"))]
    compiler = os.environ.get("CC", "cc")
    with tempfile.TemporaryDirectory(prefix="logseq-jni-boundary-") as directory:
        temporary = Path(directory)
        objects = []
        for source in [ROOT / "shared/native/logseq_https_android.c",
                       ROOT / "shared/native/logseq_crypto_android.c",
                       ROOT / "shared/test/native/jni_failures.c"]:
            output = temporary / (source.stem + ".o")
            # Desktop JNI uses void** for AttachCurrentThread; Android uses JNIEnv**.
            subprocess.run([compiler, "-Wno-incompatible-pointer-types", *includes,
                            "-c", str(source), "-o", str(output)], check=True)
            objects.append(str(output))
        shutil.copy2(ROOT / "shared/test/native/jni_failures.ml", temporary / "check.ml")
        executable = temporary / "check"
        subprocess.run(prefix + ["ocamlopt", "-thread", "-I", "+unix", "-I", "+threads",
                                  "unix.cmxa", "threads.cmxa", "check.ml",
                                  *objects, "-o", str(executable)], cwd=temporary, check=True)
        failures = []
        for mode in range(5):
            for operation in ["send", "upload", "crypto"]:
                result = subprocess.run([str(executable), str(mode), operation], capture_output=True,
                                        text=True, timeout=10)
                print(f"{'PASS' if result.returncode == 0 else 'FAIL'}: {operation}, JNI failure mode {mode}", flush=True)
                if result.returncode:
                    failures.append((operation, mode, result.returncode, result.stderr))
        if failures:
            for failure in failures:
                print(failure)
            raise SystemExit(1)


if __name__ == "__main__":
    main()
