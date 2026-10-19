#!/usr/bin/env bash
# Compile the application icon into the main bundle and merge its generated metadata.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_dir=${1:?usage: compile-ios-app-assets.sh APP_DIR PLATFORM DEPLOYMENT_TARGET}
platform=${2:?}
deployment_target=${3:?}
partial_plist=$(mktemp /tmp/logseq-app-icon.XXXXXX)
trap 'rm -f "$partial_plist"' EXIT
xcrun actool \
  --compile "$app_dir" \
  --platform "$platform" \
  --minimum-deployment-target "$deployment_target" \
  --target-device iphone --target-device ipad \
  --app-icon AppIcon \
  --output-partial-info-plist "$partial_plist" \
  "$repo_root/apple/App/Assets.xcassets" >/dev/null
python3 - "$app_dir/Info.plist" "$partial_plist" <<'PY'
import pathlib
import plistlib
import sys
info = pathlib.Path(sys.argv[1])
values = plistlib.loads(info.read_bytes())
values.update(plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes()))
info.write_bytes(plistlib.dumps(values))
PY
