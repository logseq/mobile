#!/usr/bin/env python3
"""Resolve the active Android graph using the persisted checkpoint identity."""
import argparse
import json
from pathlib import PurePosixPath
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", default="com.logseq.app")
    parser.add_argument("--graph-id", required=True)
    options = parser.parse_args()

    def read(*args):
        return subprocess.check_output(["adb", "-s", options.device, "exec-out", "run-as", options.app, *args], text=True)

    matches = []
    for entry in read("find", "files/graphs", "-name", "sync.checkpoint").splitlines():
        path = PurePosixPath(entry)
        if len(path.parts) != 4 or path.parts[:2] != ("files", "graphs"):
            continue
        try:
            checkpoint = json.loads(read("cat", str(path)))
            if isinstance(checkpoint, list) and checkpoint[:1] == ["^ "]:
                checkpoint = dict(zip(checkpoint[1::2], checkpoint[2::2]))
            if isinstance(checkpoint, dict) and checkpoint.get("~:graph-id") == options.graph_id:
                matches.append(str(path.parent))
        except (ValueError, subprocess.CalledProcessError):
            continue
    if not matches:
        raise SystemExit("No checkpoint matches the selected graph.")
    # Match the app's policy: stable named folders precede a legacy ID folder.
    print(sorted(matches, key=lambda path: (PurePosixPath(path).name == options.graph_id, path))[0])


if __name__ == "__main__":
    main()
