#!/usr/bin/env python3
"""Build and run a standalone Swift model check without XCTest."""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    source = pathlib.Path(sys.argv[1]).resolve()
    build = ["swift", "build", "--package-path", str(ROOT / "apple"), "--disable-sandbox"]
    subprocess.run(build + ["--product", "LogseqModel"], check=True)
    output = pathlib.Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="logseq-model-check-") as directory:
        executable = pathlib.Path(directory) / "check"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(output / "Modules"),
                        "-I", str(output / "LogseqCoreABI.build"), "-L", str(output), "-lLogseqModel",
                        "-Xlinker", "-rpath", "-Xlinker", str(output), str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable), *sys.argv[2:]], check=True, timeout=30)


if __name__ == "__main__":
    main()
