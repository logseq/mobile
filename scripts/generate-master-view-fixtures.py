#!/usr/bin/env python3
"""Generate view conformance fixtures with master's production CLJS runtime."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MASTER_COMMIT = "05c3ae73e08498e9e20f1b11c3eac5525e5e588d"
FIXTURE = ROOT / "shared/test/logseq/fixtures/master-views.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    upstream = args.upstream.resolve()
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=upstream, text=True
    ).strip()
    if commit != MASTER_COMMIT:
        parser.error(f"Expected master {MASTER_COMMIT}; checkout is {commit}")
    source = ROOT / "scripts/generate-master-view-fixtures.cljs"
    if MASTER_COMMIT not in source.read_text():
        parser.error("Generator and wrapper must pin the same master commit")
    with tempfile.TemporaryDirectory(prefix="logseq-master-view-fixtures-") as tmp:
        directory = Path(tmp)
        shutil.copy2(source, directory / "generate_master_view_fixtures.cljs")
        output = directory / "fixtures.json"
        compiler = {
            "target": "nodejs",
            "output-to": str(directory / "main.js"),
            "output-dir": str(directory / "out"),
        }
        options = (
            "{:target :nodejs :optimizations :none :main generate-master-view-fixtures "
            f':output-to {json.dumps(compiler["output-to"])} '
            f':output-dir {json.dumps(compiler["output-dir"])}}}'
        )
        dependencies = (
            '{:paths ["src" '
            + json.dumps(str(directory))
            + '] :deps {org.clojure/clojurescript {:mvn/version "1.11.132"}}}'
        )
        subprocess.run(
            ["clojure", "-Sdeps", dependencies, "-M", "-m", "cljs.main", "-co", options,
             "-c", "generate-master-view-fixtures"],
            cwd=upstream / "deps/db", check=True,
        )
        subprocess.run(["node", str(directory / "main.js"), str(output)], cwd="/", check=True)
        generated = json.loads(output.read_text())
        if generated["masterCommit"] != MASTER_COMMIT:
            parser.error("Fixture provenance differs from the checked source")
        if args.check:
            if generated != json.loads(FIXTURE.read_text()):
                raise SystemExit("Master view fixtures are out of date")
            print(f"Verified {len(generated['cases'])} master view conformance cases")
        else:
            FIXTURE.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(output, FIXTURE)
            print(f"Wrote {FIXTURE}")


if __name__ == "__main__":
    main()
