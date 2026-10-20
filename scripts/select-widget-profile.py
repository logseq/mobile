#!/usr/bin/env python3
"""Find a development profile compatible with the host signing and devices."""
import datetime
import fnmatch
import pathlib
import plistlib
import subprocess
import sys

host = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
identifier = host["TeamIdentifier"][0] + "." + sys.argv[2]
explicit = sys.argv[3] if len(sys.argv) > 3 else ""
roots = [pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
         pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]
candidates = [pathlib.Path(explicit)] if explicit else [p for root in roots for p in root.glob("*.mobileprovision")]
for path in candidates:
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    try:
        profile = plistlib.loads(result.stdout)
    except Exception:
        continue
    entitlements = profile.get("Entitlements", {})
    if (fnmatch.fnmatchcase(identifier, entitlements.get("application-identifier", ""))
        and entitlements.get("get-task-allow") is True
        and profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        and set(host.get("DeveloperCertificates", [])) & set(profile.get("DeveloperCertificates", []))
        and bool(set(host.get("ProvisionedDevices", [])) & set(profile.get("ProvisionedDevices", [])))):
        print(path)
        sys.exit(0)
sys.exit(f"No compatible development profile for {sys.argv[2]}. Provide an extension profile path.")
