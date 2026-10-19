"""Give SwiftPM resource bundles identities so UIKit can resolve asset catalogs."""
import plistlib
from pathlib import Path
import sys

app = Path(sys.argv[1])
for bundle in app.glob("*.bundle"):
    info = bundle / "Info.plist"
    if not info.exists():
        continue
    values = plistlib.loads(info.read_bytes())
    values.setdefault("CFBundleIdentifier", "com.logseq.resources." + bundle.stem.replace("_", "-").lower())
    values.setdefault("CFBundleName", bundle.stem)
    values.setdefault("CFBundlePackageType", "BNDL")
    info.write_bytes(plistlib.dumps(values))
