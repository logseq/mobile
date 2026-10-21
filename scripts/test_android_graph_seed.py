"""Check that the E2E CLI seeds the graph selected by checkpoint identity."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).resolve().with_name("test-android-e2e.sh")


class AndroidGraphSeedTest(unittest.TestCase):
    def check_seed(self, transit=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "bin"
            binary.mkdir()
            for name, graph_id in [("Unrelated-other", "other"), ("uiregression", "stale-identity"), ("UI_Regression-uiregression", "uiregression")]:
                graph = root / "files/graphs" / name
                graph.mkdir(parents=True)
                checkpoint = ["^ ", "~:graph-id", graph_id] if transit else {"~:graph-id": graph_id}
                (graph / "sync.checkpoint").write_text(json.dumps(checkpoint))
                (graph / "graph.sqlite").write_text("fixture database")
            (binary / "adb").write_text('''#!/usr/bin/env python3
import os, pathlib, sys
a=sys.argv[1:]; root=pathlib.Path(os.environ["SEED_ROOT"])
with (root/"commands").open("a") as f: f.write(repr(a)+"\\n")
if "run-as" in a:
    a=a[a.index("run-as")+2:]
    if a[:2]==["cat","shared_prefs/logseq.xml"]:
        print('<map><string name="logseq.selectedGraphId">uiregression</string></map>')
    elif a and a[0]=="cat":
        p=root/a[1]
        if not p.is_file(): sys.exit(1)
        print(p.read_text())
    elif a[:2]==["test","-f"]: sys.exit(0 if (root/a[2]).is_file() else 1)
    elif a and a[0]=="find":
        for p in (root/"files/graphs").glob("*/sync.checkpoint"): print(p.relative_to(root))
''')
            for name in ["maestro", "dune", "opam"]:
                (binary / name).write_text("#!/bin/sh\nexit 0\n")
            (binary / "sleep").write_text("#!/bin/sh\nexit 0\n")
            for path in binary.iterdir():
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", SEED_ROOT=folder,
                       ANDROID_SERIAL="test-device", LOGSEQ_ANDROID_E2E_SKIP_BUILD="1",
                       LOGSEQ_ANDROID_E2E_SKIP_INSTALL="1", LOGSEQ_ANDROID_E2E_RETRIES="0", LOGSEQ_ANDROID_E2E_SKIP_ANR_WATCHDOG="1")
            result = subprocess.run([str(RUNNER), "rich-content"], env=env, capture_output=True, text=True, timeout=90)
            self.assertEqual(0, result.returncode, result.stderr)
            copies = [line for line in (root / "commands").read_text().splitlines() if "'cp'" in line]
            self.assertTrue(any("files/graphs/UI_Regression-uiregression/graph.sqlite" in line for line in copies), copies)

    def test_named_graph_directory(self):
        self.check_seed()

    def test_transit_checkpoint_identity(self):
        self.check_seed(transit=True)


if __name__ == "__main__":
    unittest.main()
