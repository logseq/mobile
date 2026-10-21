#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

prune_stale_swift_resource_bundles() {
  [[ -d $swift_build_dir ]] || return 0
  [[ $swift_build_dir == "$swift_scratch_dir/"* && $swift_build_dir != "$swift_scratch_dir" ]] \
    || die "refusing to prune an invalid Swift build directory: $swift_build_dir"
  while IFS= read -r -d '' bundle; do
    rm -rf -- "$bundle"
  done < <(find "$swift_build_dir" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' -print0)
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
toolchain_root=${LOGSEQ_APPLE_TOOLCHAIN_ROOT:-$repo_root/_build/apple-toolchains}
ocaml_version=${LOGSEQ_IOS_OCAML_VERSION:-5.5.0}
deployment_target=${LOGSEQ_IOS_DEPLOYMENT_TARGET:-17.0}
team_id=${LOGSEQ_SIMULATOR_TEAM_ID:-3K44EUN829}
configuration=${LOGSEQ_IOS_CONFIGURATION:-debug}
[[ $configuration == debug || $configuration == release ]] \
  || die "LOGSEQ_IOS_CONFIGURATION must be debug or release"
[[ $configuration == release ]] && configuration_name=Release || configuration_name=Debug

sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
triple="arm64-apple-ios${deployment_target}-simulator"
target_prefix=${LOGSEQ_IOS_TOOLCHAIN_PREFIX:-$toolchain_root/ios/$triple-$ocaml_version}
swift_scratch_dir=${LOGSEQ_IOS_SWIFT_SCRATCH_PATH:-$repo_root/apple/.build}
swift_build_dir="$swift_scratch_dir/arm64-apple-ios-simulator/$configuration"
core_build_dir="$repo_root/_build/ios-core/simulator"
https_object="$core_build_dir/logseq_https_darwin.o"
crypto_object="$core_build_dir/logseq_crypto_darwin.o"
simulator_entitlements="$core_build_dir/simulator-entitlements.plist"
signature_entitlements="$core_build_dir/simulator-signature-entitlements.plist"
extension_build_dir="$core_build_dir/extensions/$configuration_name"
app_dir="$repo_root/apple/.build/Logseq.app"
xcode_app_dir="$repo_root/apple/.build/App/DerivedData/Build/Products/$configuration_name-iphonesimulator/Logseq.app"

if [[ ${LOGSEQ_IOS_PRINT_BUILD_SETTINGS:-0} == 1 ]]; then
  echo "configuration=$configuration ocaml-version=$ocaml_version target=$triple toolchain-root=$toolchain_root toolchain-prefix=$target_prefix"
  exit 0
fi

if [[ ! -x $target_prefix/bin/ocamlopt.opt ]]; then
  "$repo_root/scripts/bootstrap-ios-ocaml.sh" simulator >/dev/null
fi

ocaml_lib="$target_prefix/lib/ocaml"
clang=$(xcrun --sdk iphonesimulator --find clang)
clangxx=$(xcrun --sdk iphonesimulator --find clang++)
mkdir -p "$core_build_dir"

# Apple marks libffi unavailable in the iOS SDK headers; ctypes-foreign's stub
# build needs real libffi headers and the final link needs a real libffi.a.
ffi_prefix=$("$repo_root/scripts/build-mobile-libffi.sh" \
  aarch64-apple-darwin \
  "$toolchain_root/ios/libffi-$triple" \
  "$clang -target $triple -isysroot $sdk_path" \
  "$clangxx -target $triple -isysroot $sdk_path")

plutil -create xml1 "$simulator_entitlements"
plutil -insert application-identifier -string "${team_id}.com.logseq.logseq" "$simulator_entitlements"
plutil -insert keychain-access-groups -json "[\"${team_id}.com.logseq.logseq\"]" "$simulator_entitlements"
plutil -insert 'com\.apple\.security\.application-groups' -json '["group.com.logseq.logseq"]' "$simulator_entitlements"
plutil -create xml1 "$signature_entitlements"
plutil -insert 'com\.apple\.security\.application-groups' -json '["group.com.logseq.logseq"]' "$signature_entitlements"

core_object=$(LOGSEQ_SQLITE_LIB_DIR="$sdk_path/usr/lib" \
  LOGSEQ_SQLITE_LINK_FILE="$sdk_path/usr/lib/libsqlite3.tbd" \
  PKG_CONFIG_PATH="$ffi_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  "$repo_root/scripts/build-mobile-ocaml.sh" "$target_prefix" ios_simulator)

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

swift_build_args=(
  --configuration "$configuration"
  --disable-keychain
  --package-path "$repo_root/apple"
  --product LogseqShell
  --triple "$triple"
  --sdk "$sdk_path"
)
if [[ ${LOGSEQ_IOS_ENABLE_TESTING:-0} == 1 ]]; then
  swift_build_args+=(-Xswiftc -enable-testing)
fi

prune_stale_swift_resource_bundles
LOGSEQ_NATIVE_LINK_INPUTS="$native_link_inputs" \
LOGSEQ_SIMULATOR_ENTITLEMENTS="$simulator_entitlements" \
swift build "${swift_build_args[@]}"

xcodebuild \
  -project "$repo_root/apple/App/Logseq.xcodeproj" \
  -target LogseqShareExtension \
  -target LogseqWidgets \
  -configuration "$configuration_name" \
  -sdk iphonesimulator \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$extension_build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet \
  build

if [[ -d $app_dir ]]; then
  chmod -R u+w "$app_dir"
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir"
if [[ -f "$xcode_app_dir/Info.plist" ]]; then
  cp "$xcode_app_dir/Info.plist" "$app_dir/Info.plist"
else
  cp "$repo_root/apple/App/Info.plist" "$app_dir/Info.plist"
  "$repo_root/scripts/configure-ios-info-plist.sh" "$app_dir/Info.plist" "com.logseq.logseq" "$deployment_target" "iPhoneSimulator"
fi
cp "$swift_build_dir/LogseqShell" "$app_dir/Logseq"
"$repo_root/scripts/compile-ios-app-assets.sh" "$app_dir" iphonesimulator "$deployment_target"

for bundle in "$swift_build_dir"/*.bundle; do
  [[ -d $bundle ]] || continue
  cp -R "$bundle" "$app_dir/"
done

plugins_dir="$app_dir/PlugIns"
mkdir -p "$plugins_dir"
for extension in LogseqShareExtension LogseqWidgets; do
  extension_product="$extension_build_dir/$extension.appex"
  [[ -d $extension_product ]] || die "missing simulator extension: $extension_product"
  cp -R "$extension_product" "$plugins_dir/"
  for key in CFBundleShortVersionString CFBundleVersion; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_dir/Info.plist")
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plugins_dir/$extension.appex/Info.plist"
  done
done
codesign --force --sign - --entitlements "$repo_root/apple/App/ShareExtension/ShareExtension.entitlements" \
  --timestamp=none --generate-entitlement-der "$plugins_dir/LogseqShareExtension.appex"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  "$plugins_dir/LogseqWidgets.appex"

python3 "$repo_root/scripts/configure-ios-resource-bundles.py" "$app_dir"

logseq_resource_bundle="$app_dir/logseq_Logseq.bundle"
if [[ -d $logseq_resource_bundle ]]; then
  xcrun actool \
    --compile "$logseq_resource_bundle" \
    --platform iphonesimulator \
    --minimum-deployment-target "$deployment_target" \
    --target-device iphone \
    --target-device ipad \
    "$repo_root/apple/Sources/Logseq/Resources/Icons.xcassets" \
    "$repo_root/apple/Sources/Logseq/Resources/Module.xcassets" >/dev/null
fi

"$repo_root/scripts/extract-app-intents.sh" LogseqShell "$sdk_path" "$triple" \
  "$deployment_target" "$app_dir" \
  -I "$swift_build_dir/Modules" \
  -Xcc "-fmodule-map-file=$swift_build_dir/LogseqCoreABI.build/module.modulemap" \
  -I "$repo_root/apple/Sources/LogseqCoreABI/include" \
  "$repo_root/apple/App/Sources/Main.swift" "$repo_root/apple/App/Sources/QuickActions.swift"

codesign --force --sign - --entitlements "$signature_entitlements" \
  --timestamp=none --generate-entitlement-der "$app_dir"

python3 "$repo_root/scripts/verify-ios-shortcuts.py" "$app_dir"
python3 "$repo_root/scripts/verify-ios-share-extension.py" "$app_dir"
python3 "$repo_root/scripts/verify-ios-native-symbols.py" "$app_dir"
echo "$app_dir"
