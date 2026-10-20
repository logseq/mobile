#!/usr/bin/env python3
"""Run the Swift model suite directly with Swift Testing, without XCTest."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    build = ["swift", "build", "--package-path", str(ROOT / "apple"), "--disable-sandbox"]
    subprocess.run(build + ["--target", "LogseqModelTests"], check=True)
    output = pathlib.Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
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
                        str(source), *map(str, sorted((output / "LogseqModelTests.build").glob("*.o"))),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable), "--no-parallel"], check=True, timeout=180)


if __name__ == "__main__":
    main()
