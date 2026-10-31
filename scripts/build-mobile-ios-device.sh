#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ios_device_config=${LOGSEQ_IOS_CONFIG:-$repo_root/.logseq-ios-device.env}
[[ -f $ios_device_config ]] && source "$ios_device_config"

toolchain_root=${LOGSEQ_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_IOS_DEPLOYMENT_TARGET:-17.0}
bundle_id=${LOGSEQ_IOS_BUNDLE_ID:-com.logseq.logseq}
build_configuration=${LOGSEQ_IOS_BUILD_CONFIGURATION:-release}
profile=${LOGSEQ_IOS_PROFILE:-}
signing_identity=${LOGSEQ_IOS_SIGNING_IDENTITY:-Apple Development}
signing_keychain=${LOGSEQ_IOS_KEYCHAIN:-}
signing_keychain_password=${LOGSEQ_IOS_KEYCHAIN_PASSWORD-}
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
triple="arm64-apple-ios${deployment_target}"
target_prefix=${LOGSEQ_IOS_TOOLCHAIN_PREFIX:-$toolchain_root/ios/$triple-$ocaml_version}
swift_scratch_dir=${LOGSEQ_IOS_SWIFT_SCRATCH_PATH:-$repo_root/apple/.build/ios-device}
swift_build_dir="$swift_scratch_dir/arm64-apple-ios/$build_configuration"
core_build_dir="$repo_root/_build/ios-core/device"
https_object="$core_build_dir/logseq_https_darwin.o"
crypto_object="$core_build_dir/logseq_crypto_darwin.o"
app_dir="$repo_root/apple/.build/Logseq-device.app"
profile_plist="$core_build_dir/profile.plist"
entitlements="$core_build_dir/entitlements.plist"

die() {
  echo "error: $*" >&2
  exit 1
}

write_development_entitlements() {
  python3 - "$1" "$2" "$3" "$4" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

source_path, profile_path, bundle_id, output_path = sys.argv[1:]
requested = plistlib.loads(Path(source_path).read_bytes())
profile = plistlib.loads(Path(profile_path).read_bytes())
app_id = profile["ApplicationIdentifierPrefix"][0] + "." + bundle_id
requested.update({
    "application-identifier": app_id,
    "com.apple.developer.team-identifier": profile["TeamIdentifier"][0],
    "keychain-access-groups": [app_id],
    "get-task-allow": profile["Entitlements"].get("get-task-allow", False),
})
Path(output_path).write_bytes(plistlib.dumps(requested))
PYTHON
}

prune_stale_swift_resource_bundles() {
  [[ -d $swift_build_dir ]] || return 0
  [[ $swift_build_dir == "$swift_scratch_dir/"* && $swift_build_dir != "$swift_scratch_dir" ]] \
    || die "refusing to prune an invalid Swift build directory: $swift_build_dir"
  while IFS= read -r -d '' bundle; do
    rm -rf -- "$bundle"
  done < <(find "$swift_build_dir" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' -print0)
}

[[ $build_configuration == debug || $build_configuration == release ]] \
  || die "unsupported iOS build configuration: $build_configuration"

if [[ ${LOGSEQ_IOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$build_configuration swift-build-dir=$swift_build_dir ocaml-version=$ocaml_version target=$triple toolchain-root=$toolchain_root toolchain-prefix=$target_prefix profile=$profile signing-identity=$signing_identity"
  exit 0
fi

# Signing assets are only needed when assembling the dev-profile .app; the
# LOGSEQ_IOS_LINK_INPUTS_ONLY release path produces OCaml objects for the
# fastlane archive and skips all provisioning checks.
if [[ ${LOGSEQ_IOS_LINK_INPUTS_ONLY:-0} != 1 ]]; then
  [[ -n $profile ]] || die "set LOGSEQ_IOS_PROFILE to a development provisioning profile for $bundle_id"
  [[ -f $profile ]] || die "provisioning profile was not found: $profile"
  if [[ -n $signing_keychain && ! -f $signing_keychain ]]; then
    die "signing keychain was not found: $signing_keychain"
  fi

  codesign_keychain_args=()
  [[ -n $signing_keychain ]] && codesign_keychain_args=(--keychain "$signing_keychain")
  original_keychain_search_list=()
  restore_keychain_search_list() {
    local exit_status=$?
    if ((${#original_keychain_search_list[@]} > 0)); then
      security list-keychains -d user -s "${original_keychain_search_list[@]}" >/dev/null || true
    fi
    return "$exit_status"
  }

  if [[ -n $signing_keychain ]]; then
    while IFS='"' read -r _ keychain_path _; do
      [[ -n $keychain_path ]] && original_keychain_search_list+=("$keychain_path")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s \
      "${original_keychain_search_list[@]}" "$signing_keychain"
    trap restore_keychain_search_list EXIT
    if [[ ${LOGSEQ_IOS_KEYCHAIN_PASSWORD+x} == x ]]; then
      security unlock-keychain -p "$signing_keychain_password" "$signing_keychain"
    fi
  fi

  security cms -D -i "$profile" >"$profile_plist"
  profile_app_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$profile_plist")
  team_id=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$profile_plist")
  expected_app_id="$team_id.$bundle_id"
  if [[ $profile_app_id != "$expected_app_id" && $profile_app_id != "$team_id.*" ]]; then
    die "profile app id is $profile_app_id, expected $expected_app_id or $team_id.*"
  fi
fi

mkdir -p "$core_build_dir"

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$repo_root/scripts/bootstrap-ios-ocaml.sh" device >/dev/null
fi

ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphoneos --find clang)
clangxx=$(xcrun --sdk iphoneos --find clang++)

# Apple marks libffi unavailable in the iOS SDK headers; ctypes-foreign's stub
# build needs real libffi headers and the final link needs a real libffi.a.
ffi_prefix=$("$repo_root/scripts/build-mobile-libffi.sh" \
  aarch64-apple-darwin \
  "$toolchain_root/ios/libffi-$triple" \
  "$clang -target $triple -isysroot $sdk_path" \
  "$clangxx -target $triple -isysroot $sdk_path")

core_object=$(LOGSEQ_SQLITE_LIB_DIR="$sdk_path/usr/lib" \
  LOGSEQ_SQLITE_LINK_FILE="$sdk_path/usr/lib/libsqlite3.tbd" \
  PKG_CONFIG_PATH="$ffi_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix" ios_device)

for source in logseq_https_darwin.m logseq_crypto_darwin.m; do
  "$clang" \
    -target "$triple" \
    -isysroot "$sdk_path" \
    -fobjc-arc \
    -fPIC \
    -I "$ocaml_lib" \
    -c "$repo_root/shared/native/$source" \
    -o "$core_build_dir/${source%.m}.o"
done

native_link_fingerprint=$(shasum -a 256 \
  "$core_object" "$https_object" "$crypto_object" "$ocaml_lib/libthreadsnat.a" \
  | shasum -a 256 | cut -d ' ' -f 1)
native_link_dir="$core_build_dir/native-link-inputs/$native_link_fingerprint"
fingerprinted_core_object="$native_link_dir/logseq_runtime.o"
mkdir -p "$native_link_dir"
[[ -s $fingerprinted_core_object ]] || cp "$core_object" "$fingerprinted_core_object"
native_link_inputs="$fingerprinted_core_object:$https_object:$crypto_object:$ocaml_lib/libthreadsnat.a:-L$ffi_prefix/lib"
# Both build paths must publish the current core. A later archive can follow a
# development build and must not reuse a manifest from an older core build.
printf '%s' "$native_link_inputs" > "$core_build_dir/native-link-inputs.txt"

# Release path: xcodebuild archives the app via the Xcode project and links
# the OCaml core through LOGSEQ_NATIVE_LINK_INPUTS. Emit just the inputs so
# the fastlane lane can pass them on without running the dev-profile .app
# assembly below.
if [[ ${LOGSEQ_IOS_LINK_INPUTS_ONLY:-0} == 1 ]]; then
  echo "wrote $core_build_dir/native-link-inputs.txt"
  exit 0
fi

prune_stale_swift_resource_bundles
LOGSEQ_NATIVE_LINK_INPUTS="$native_link_inputs" \
swift build \
  -c "$build_configuration" \
  --scratch-path "$swift_scratch_dir" \
  --disable-keychain \
  --package-path "$repo_root/apple" \
  --product LogseqShell \
  --triple "$triple" \
  --sdk "$sdk_path"

if [[ -d $app_dir ]]; then
  chmod -R u+w "$app_dir"
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir"
cp "$repo_root/apple/App/Info.plist" "$app_dir/Info.plist"
cp "$profile" "$app_dir/embedded.mobileprovision"
"$repo_root/scripts/configure-ios-info-plist.sh" "$app_dir/Info.plist" "$bundle_id" "$deployment_target" "iPhoneOS"
cp "$swift_build_dir/LogseqShell" "$app_dir/Logseq"
"$repo_root/scripts/compile-ios-app-assets.sh" "$app_dir" iphoneos "$deployment_target"

for bundle in "$swift_build_dir"/*.bundle; do
  [[ -d $bundle ]] || continue
  cp -R "$bundle" "$app_dir/"
done

python3 "$repo_root/scripts/configure-ios-resource-bundles.py" "$app_dir"

logseq_resource_bundle="$app_dir/logseq_Logseq.bundle"
if [[ -d $logseq_resource_bundle ]]; then
  "$repo_root/scripts/compile-ios-app-assets.sh" "$logseq_resource_bundle" iphoneos "$deployment_target" resources
fi

# SwiftPM does not run Xcode's App Intents metadata build phase.
"$repo_root/scripts/extract-app-intents.sh" LogseqShell "$sdk_path" "$triple" \
  "$deployment_target" "$app_dir" \
  -I "$swift_build_dir/Modules" \
  -Xcc "-fmodule-map-file=$swift_build_dir/LogseqCoreABI.build/module.modulemap" \
  -I "$repo_root/apple/Sources/LogseqCoreABI/include" \
  "$repo_root/apple/App/Sources/Main.swift" "$repo_root/apple/App/Sources/QuickActions.swift"

widget_bundle_id=${LOGSEQ_IOS_WIDGET_BUNDLE_ID:-$bundle_id.shortcuts}
widget_profile=$(python3 "$repo_root/scripts/select-widget-profile.py" \
  "$profile_plist" "$widget_bundle_id" "${LOGSEQ_IOS_WIDGET_PROFILE:-}")
widget_dir="$app_dir/PlugIns/LogseqWidgets.appex"
widget_profile_plist="$core_build_dir/widget-profile.plist"
widget_entitlements="$core_build_dir/widget-entitlements.plist"
# Use Xcode's extension build pipeline so WidgetKit receives the same platform
# metadata and linker settings as an extension built from the project.
widget_build_dir="$repo_root/apple/.build/ios-device-extensions"
configuration_name=Debug
[[ $build_configuration == release ]] && configuration_name=Release
xcodebuild -project "$repo_root/apple/App/Logseq.xcodeproj" \
  -target LogseqWidgets -configuration "$configuration_name" \
  -sdk iphoneos -arch arm64 ONLY_ACTIVE_ARCH=YES \
  IPHONEOS_DEPLOYMENT_TARGET="$deployment_target" \
  PRODUCT_BUNDLE_IDENTIFIER="$widget_bundle_id" \
  CONFIGURATION_BUILD_DIR="$widget_build_dir" CODE_SIGNING_ALLOWED=NO -quiet build
mkdir -p "$app_dir/PlugIns"
cp -R "$widget_build_dir/LogseqWidgets.appex" "$widget_dir"
for key in CFBundleShortVersionString CFBundleVersion; do
  value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_dir/Info.plist")
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$widget_dir/Info.plist"
done
cp "$widget_profile" "$widget_dir/embedded.mobileprovision"
security cms -D -i "$widget_profile" > "$widget_profile_plist"
write_development_entitlements "$repo_root/apple/App/Entitlements.plist" \
  "$widget_profile_plist" "$widget_bundle_id" "$widget_entitlements"
codesign "${codesign_keychain_args[@]}" --force --sign "$signing_identity" --timestamp=none \
  --entitlements "$widget_entitlements" "$widget_dir"

share_bundle_id=${LOGSEQ_IOS_SHARE_BUNDLE_ID:-$bundle_id.ShareViewController}
share_profile=$(python3 "$repo_root/scripts/select-widget-profile.py" \
  "$profile_plist" "$share_bundle_id" "${LOGSEQ_IOS_SHARE_PROFILE:-}")
share_dir="$app_dir/PlugIns/LogseqShareExtension.appex"
share_profile_plist="$core_build_dir/share-profile.plist"
share_entitlements="$core_build_dir/share-entitlements.plist"
xcodebuild -project "$repo_root/apple/App/Logseq.xcodeproj" \
  -target LogseqShareExtension -configuration "$configuration_name" \
  -sdk iphoneos -arch arm64 ONLY_ACTIVE_ARCH=YES \
  IPHONEOS_DEPLOYMENT_TARGET="$deployment_target" \
  PRODUCT_BUNDLE_IDENTIFIER="$share_bundle_id" \
  CONFIGURATION_BUILD_DIR="$widget_build_dir" CODE_SIGNING_ALLOWED=NO -quiet build
cp -R "$widget_build_dir/LogseqShareExtension.appex" "$share_dir"
for key in CFBundleShortVersionString CFBundleVersion; do
  value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_dir/Info.plist")
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$share_dir/Info.plist"
done
cp "$share_profile" "$share_dir/embedded.mobileprovision"
security cms -D -i "$share_profile" > "$share_profile_plist"
write_development_entitlements "$repo_root/apple/App/ShareExtension/ShareExtension.entitlements" \
  "$share_profile_plist" "$share_bundle_id" "$share_entitlements"
codesign "${codesign_keychain_args[@]}" --force --sign "$signing_identity" --timestamp=none \
  --entitlements "$share_entitlements" "$share_dir"

write_development_entitlements "$repo_root/apple/App/Entitlements.plist" \
  "$profile_plist" "$bundle_id" "$entitlements"
codesign "${codesign_keychain_args[@]}" --force --sign "$signing_identity" --timestamp=none \
  --entitlements "$entitlements" "$app_dir"
codesign --verify --deep --strict "$app_dir"

python3 "$repo_root/scripts/verify-ios-shortcuts.py" "$app_dir"
python3 "$repo_root/scripts/verify-ios-share-extension.py" "$app_dir"
python3 "$repo_root/scripts/verify-ios-native-symbols.py" "$app_dir"
echo "$app_dir"
