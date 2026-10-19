#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_dir=${LOGSEQ_IOS_APP_DIR:-$repo_root/apple/.build/Logseq-device.app}
info_plist="$app_dir/Info.plist"
failures=0

check_plist() {
  local name=$1
  local expected=$2
  shift 2

  local output
  if ! output=$(/usr/libexec/PlistBuddy "$@" "$info_plist" 2>&1); then
    echo "not ok - $name: $output" >&2
    failures=$((failures + 1))
    return
  fi

  if [[ $output != "$expected" ]]; then
    echo "not ok - $name: expected '$expected', got '$output'" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

check_plist_exists() {
  local name=$1
  shift

  local output
  if ! output=$(/usr/libexec/PlistBuddy "$@" "$info_plist" 2>&1); then
    echo "not ok - $name: $output" >&2
    failures=$((failures + 1))
    return
  fi

  echo "ok - $name"
}

[[ -f $info_plist ]] || {
  echo "error: app Info.plist was not found: $info_plist" >&2
  exit 1
}

check_plist "iPhone device family is declared" "1" -c "Print :UIDeviceFamily:0"
check_plist "iPad device family is declared" "2" -c "Print :UIDeviceFamily:1"
check_plist_exists "generated launch screen is present" -c "Print :UILaunchScreen:UILaunchScreen"
check_plist "scene manifest supports multiple scenes" "true" -c "Print :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes"
check_plist "indirect input support is present" "true" -c "Print :UIApplicationSupportsIndirectInputEvents"
check_plist "portrait orientation is present" "UIInterfaceOrientationPortrait" -c "Print :UISupportedInterfaceOrientations:2"
check_plist "background fetch mode is present" "fetch" -c "Print :UIBackgroundModes:0"
check_plist "background audio mode is present" "audio" -c "Print :UIBackgroundModes:1"
check_plist_exists "microphone usage description is present" -c "Print :NSMicrophoneUsageDescription"
check_plist_exists "speech usage description is present" -c "Print :NSSpeechRecognitionUsageDescription"
check_plist "primary app icon is declared" "AppIcon" -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName"
check_plist_exists "primary app icon files are declared" -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0"
if [[ ! -f "$app_dir/Assets.car" ]]; then
  echo "not ok - compiled app icon asset catalog is missing" >&2
  failures=$((failures + 1))
fi
check_plist "background refresh task identifier is present" "com.logseq.logseq.refresh" -c "Print :BGTaskSchedulerPermittedIdentifiers:0"

if [[ $failures -ne 0 ]]; then
  exit 1
fi
