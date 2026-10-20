#!/usr/bin/env python3
"""Build and run the Swift UI suite in an app host using Swift Testing directly."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    core = ROOT / "_build/ios-core/simulator"
    runtime = max(core.glob("native-link-inputs/*/logseq_runtime.o"), key=lambda path: path.stat().st_mtime)
    toolchain = ROOT / "_build/apple-toolchains/ios"
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    triple = "arm64-apple-ios17.0-simulator"
    environment = os.environ.copy()
    environment["LOGSEQ_NATIVE_LINK_INPUTS"] = ":".join(map(str, [runtime,
        core / "logseq_https_darwin.o", core / "logseq_crypto_darwin.o",
        toolchain / (triple + "-5.5.0/lib/ocaml/libthreadsnat.a")])) + ":-L" + str(toolchain / ("libffi-" + triple + "/lib"))
    environment["LOGSEQ_SIMULATOR_ENTITLEMENTS"] = str(core / "simulator-entitlements.plist")
    subprocess.run(["swift", "build", "--package-path", str(ROOT / "apple"), "--disable-sandbox",
                    "--triple", triple, "--sdk", sdk, "--target", "LogseqTests", "-Xswiftc", "-enable-testing"],
                   env=environment, check=True)
    environment["LOGSEQ_SWIFT_UI_TEST_SUITE"] = "1"
    subprocess.run(["python3", str(ROOT / "apple/Tests/UI/run-simulator-runtime-check.py"),
                    str(ROOT / "apple/Tests/UI/swift-ui-suite.swift"), "SwiftUISuite"], env=environment, check=True)


if __name__ == "__main__":
    main()
