#!/usr/bin/env python3
"""Run the simulator's Swift build invocation with native Bash 3.2 and PATH Bash."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "scripts/build-mobile-ios-simulator.sh").read_text()
    block = re.search(r"^swift_(?:extra|build)_args=\(.*?(?=^xcodebuild)", source, re.MULTILINE | re.DOTALL)
    if not block:
        raise SystemExit("Simulator Swift build invocation was not found")
    values = {"configuration": "release", "repo_root": "/tmp/project with spaces",
              "triple": "arm64-apple-ios17.0-simulator", "sdk_path": "/tmp/iOS SDK",
              "native_link_inputs": "runtime.o:crypto.o", "simulator_entitlements": "/tmp/entitlements.plist"}
    preamble = "set -euo pipefail\n" + "\n".join(name + "=" + shlex.quote(value) for name, value in values.items())
    preamble += "\nprune_stale_swift_resource_bundles() { :; }\n"
    expected = ["build", "--configuration", "release", "--disable-keychain", "--package-path",
                values["repo_root"] + "/apple", "--product", "LogseqShell", "--triple", values["triple"],
                "--sdk", values["sdk_path"]]
    shells = list(dict.fromkeys(["/bin/bash", shutil.which("bash")]))
    failures = 0
    with tempfile.TemporaryDirectory(prefix="logseq-swift-arguments-") as directory:
        swift = Path(directory) / "swift"
        swift.write_text("#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
        swift.chmod(0o755)
        for shell in shells:
            for testing in ["0", "1"]:
                environment = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                                   LOGSEQ_IOS_ENABLE_TESTING=testing)
                result = subprocess.run([shell, "-c", preamble + block.group()], env=environment,
                                        capture_output=True, text=True, timeout=10)
                wanted = expected + (["-Xswiftc", "-enable-testing"] if testing == "1" else [])
                good = result.returncode == 0 and json.loads(result.stdout) == wanted
                print(f"{'PASS' if good else 'FAIL'}: {shell}, testing={testing}")
                if not good:
                    failures += 1
                    print(result.stderr.strip() or result.stdout.strip())
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
