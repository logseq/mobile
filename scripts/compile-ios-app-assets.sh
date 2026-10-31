#!/usr/bin/env bash
# Reuse compiled asset catalogs when their inputs and Apple toolchain are unchanged.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_dir=${1:?usage: compile-ios-app-assets.sh OUTPUT_DIR PLATFORM DEPLOYMENT_TARGET [app|resources]}
platform=${2:?}
deployment_target=${3:?}
kind=${4:-app}
case $kind in
  app) catalogs=("$repo_root/apple/App/Assets.xcassets") ;;
  resources) catalogs=("$repo_root/apple/Sources/Logseq/Resources/Icons.xcassets" "$repo_root/apple/Sources/Logseq/Resources/Module.xcassets") ;;
  *) echo "error: unknown asset catalog kind: $kind" >&2; exit 1 ;;
esac
started=$SECONDS
fingerprint=$(python3 - "$platform" "$deployment_target" "$(xcodebuild -version)" \
  "$(xcrun --sdk "$platform" --show-sdk-build-version)" "${BASH_SOURCE[0]}" "${catalogs[@]}" <<'PY'
import hashlib
import pathlib
import sys
digest = hashlib.sha256()
for value in sys.argv[1:5]:
    digest.update(value.encode() + b"\0")
for source in map(pathlib.Path, sys.argv[5:]):
    files = sorted(p for p in source.rglob("*") if p.is_file()) if source.is_dir() else [source]
    for path in files:
        digest.update(str(path.relative_to(source.parent)).encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
)
cache_root="$repo_root/_build/ios-core/asset-catalogs/$platform/$deployment_target/$kind"
cache_dir="$cache_root/$fingerprint"
if [[ ! -f $cache_dir/complete ]]; then
  mkdir -p "$cache_root"
  work=$(mktemp -d "$cache_root/.compile.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  mkdir "$work/output"
  actool_args=(--compile "$work/output" --platform "$platform"
    --minimum-deployment-target "$deployment_target"
    --target-device iphone --target-device ipad)
  if [[ $kind == app ]]; then
    actool_args+=(--app-icon AppIcon --output-partial-info-plist "$work/Info.plist")
  fi
  xcrun actool "${actool_args[@]}" "${catalogs[@]}" >/dev/null
  touch "$work/complete"
  python3 - "$work" "$cache_dir" <<'PY'
import os
import pathlib
import sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError:
    if not (pathlib.Path(sys.argv[2]) / "complete").is_file():
        raise
PY
  echo "[ios-build] $kind asset catalogs: compiled in $((SECONDS - started))s" >&2
else
  echo "[ios-build] $kind asset catalogs: cache hit in $((SECONDS - started))s" >&2
fi
cp -R "$cache_dir/output/." "$app_dir/"
[[ $kind == app ]] || exit 0
partial_plist="$cache_dir/Info.plist"
python3 - "$app_dir/Info.plist" "$partial_plist" <<'PY'
import pathlib
import plistlib
import sys
info = pathlib.Path(sys.argv[1])
values = plistlib.loads(info.read_bytes())
values.update(plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes()))
info.write_bytes(plistlib.dumps(values))
PY
