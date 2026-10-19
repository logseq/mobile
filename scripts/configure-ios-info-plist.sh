#!/usr/bin/env bash

set -euo pipefail

info_plist=${1:?usage: configure-ios-info-plist.sh INFO_PLIST BUNDLE_ID DEPLOYMENT_TARGET SUPPORTED_PLATFORM}
bundle_id=${2:?usage: configure-ios-info-plist.sh INFO_PLIST BUNDLE_ID DEPLOYMENT_TARGET SUPPORTED_PLATFORM}
deployment_target=${3:?usage: configure-ios-info-plist.sh INFO_PLIST BUNDLE_ID DEPLOYMENT_TARGET SUPPORTED_PLATFORM}
supported_platform=${4:?usage: configure-ios-info-plist.sh INFO_PLIST BUNDLE_ID DEPLOYMENT_TARGET SUPPORTED_PLATFORM}
plistbuddy=/usr/libexec/PlistBuddy

set_string() {
  local key=$1
  local value=$2
  "$plistbuddy" -c "Set :$key $value" "$info_plist" 2>/dev/null \
    || "$plistbuddy" -c "Add :$key string $value" "$info_plist"
}

set_bool() {
  local key=$1
  local value=$2
  "$plistbuddy" -c "Set :$key $value" "$info_plist" 2>/dev/null \
    || "$plistbuddy" -c "Add :$key bool $value" "$info_plist"
}

reset_key() {
  local key=$1
  "$plistbuddy" -c "Delete :$key" "$info_plist" 2>/dev/null || true
}

set_string "CFBundleDevelopmentRegion" "en"
set_string "CFBundleExecutable" "Logseq"
set_string "CFBundleIdentifier" "$bundle_id"
set_string "CFBundleInfoDictionaryVersion" "6.0"
set_string "CFBundleName" "Logseq"
set_string "CFBundlePackageType" "APPL"
set_string "CFBundleShortVersionString" "0.0.1"
set_string "CFBundleVersion" "1"
set_bool "ITSAppUsesNonExemptEncryption" "false"
set_bool "LSRequiresIPhoneOS" "true"
set_string "MinimumOSVersion" "$deployment_target"
set_bool "UIApplicationSupportsIndirectInputEvents" "true"
set_string "UIStatusBarStyle" "UIStatusBarStyleDefault"
set_string "NSPhotoLibraryAddUsageDescription" "Save images from your Logseq graph to Photos."
set_string "NSLocalNetworkUsageDescription" "Connect to a Logseq graph sync server on your local network."

reset_key "NSAppTransportSecurity"
"$plistbuddy" -c "Add :NSAppTransportSecurity dict" "$info_plist"
"$plistbuddy" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$info_plist"

reset_key "CFBundleSupportedPlatforms"
"$plistbuddy" -c "Add :CFBundleSupportedPlatforms array" "$info_plist"
"$plistbuddy" -c "Add :CFBundleSupportedPlatforms:0 string $supported_platform" "$info_plist"

reset_key "UIDeviceFamily"
"$plistbuddy" -c "Add :UIDeviceFamily array" "$info_plist"
"$plistbuddy" -c "Add :UIDeviceFamily:0 integer 1" "$info_plist"
"$plistbuddy" -c "Add :UIDeviceFamily:1 integer 2" "$info_plist"

reset_key "UILaunchScreen"
"$plistbuddy" -c "Add :UILaunchScreen dict" "$info_plist"
"$plistbuddy" -c "Add :UILaunchScreen:UILaunchScreen dict" "$info_plist"

reset_key "UIApplicationSceneManifest"
"$plistbuddy" -c "Add :UIApplicationSceneManifest dict" "$info_plist"
"$plistbuddy" -c "Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool true" "$info_plist"
"$plistbuddy" -c "Add :UIApplicationSceneManifest:UISceneConfigurations dict" "$info_plist"

reset_key "UISupportedInterfaceOrientations"
"$plistbuddy" -c "Add :UISupportedInterfaceOrientations array" "$info_plist"
"$plistbuddy" -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationLandscapeLeft" "$info_plist"
"$plistbuddy" -c "Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationLandscapeRight" "$info_plist"
"$plistbuddy" -c "Add :UISupportedInterfaceOrientations:2 string UIInterfaceOrientationPortrait" "$info_plist"
"$plistbuddy" -c "Add :UISupportedInterfaceOrientations:3 string UIInterfaceOrientationPortraitUpsideDown" "$info_plist"

reset_key "UIBackgroundModes"
"$plistbuddy" -c "Add :UIBackgroundModes array" "$info_plist"
"$plistbuddy" -c "Add :UIBackgroundModes:0 string fetch" "$info_plist"
"$plistbuddy" -c "Add :UIBackgroundModes:1 string audio" "$info_plist"

reset_key "BGTaskSchedulerPermittedIdentifiers"
"$plistbuddy" -c "Add :BGTaskSchedulerPermittedIdentifiers array" "$info_plist"
"$plistbuddy" -c "Add :BGTaskSchedulerPermittedIdentifiers:0 string com.logseq.logseq.refresh" "$info_plist"
