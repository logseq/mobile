#!/usr/bin/env python3
"""Run the Swift model suite directly with Swift Testing, without XCTest."""
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    configuration = os.environ.get("LOGSEQ_SWIFT_CONFIGURATION", "debug")
    if configuration not in ("debug", "release"):
        raise SystemExit("LOGSEQ_SWIFT_CONFIGURATION must be debug or release")
    build = ["swift", "build", "--configuration", configuration, "--package-path", str(ROOT / "apple"), "--disable-sandbox", "-Xswiftc", "-enable-testing"]
    subprocess.run(build + ["--target", "LogseqModelTests"], check=True)
    subprocess.run(build + ["--product", "LogseqModel"], check=True)
    output = pathlib.Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
    object_map = json.loads((output / "LogseqModelTests.build/output-file-map.json").read_text())
    test_objects = sorted(entry["object"] for source, entry in object_map.items() if source and "object" in entry)
    developer = pathlib.Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    with tempfile.TemporaryDirectory(prefix="logseq-model-suite-") as directory:
        source = pathlib.Path(directory) / "main.swift"
        source.write_text("import Testing\nimport Darwin\n@main struct ModelTests { static func main() async { let result: CInt = await Testing.__swiftPMEntryPoint(); exit(result) } }\n")
        executable = pathlib.Path(directory) / "tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-F", str(frameworks), "-framework", "Testing",
                        "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                        "-I", str(output / "Modules"), "-I", str(output / "LogseqCoreABI.build"),
                        "-L", str(output), "-lLogseqModel", "-Xlinker", "-rpath", "-Xlinker", str(output),
                        str(source), *test_objects,
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable), "--no-parallel"], check=True, timeout=180)


if __name__ == "__main__":
    main()
