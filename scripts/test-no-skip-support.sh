#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

die() {
  echo "error: $*" >&2
  exit 1
}

[[ ! -e "$repo_root/Vendor/LUIAppleBackend" ]] \
  || die "Apple backend must come from the LUI package, not a local copy"

for path in \
  "$repo_root/Skip.env" \
  "$repo_root/Android/settings.gradle.kts" \
  "$repo_root/Android/app/build.gradle.kts" \
  "$repo_root/apple/Sources/Logseq/Skip" \
  "$repo_root/apple/Sources/LogseqModel/Skip" \
  "$repo_root/apple/Tests/LogseqTests/Skip" \
  "$repo_root/apple/Tests/LogseqModelTests/Skip"; do
  [[ ! -e "$path" ]] || die "legacy Skip artifact remains: ${path#"$repo_root/"}"
done

if grep -Eq 'source\.skip\.tools|Skip(UI|Foundation|Model|FFI|Test)|skipstone' "$repo_root/apple/Package.swift"; then
  die "Package.swift still depends on Skip"
fi

if grep -REn '#(if|elseif).*(^|[^A-Za-z])!?SKIP([^A-Za-z]|$)' \
  "$repo_root/apple/Sources" "$repo_root/apple/Tests" \
  --include='*.swift' >/dev/null; then
  die "Swift sources still contain Skip conditional compilation"
fi

if grep -Eq 'profile[[:space:]]+AndroidOS[[:space:]]+SwiftUIHost' \
  "$repo_root/shared/src/logseq/view.ml"; then
  die "the extension registry still registers the removed Android SwiftUI host"
fi

if grep -Eq 'SkipStone|Run skip gradle|Skip\.env|skip gradle' \
  "$repo_root/apple/App/Logseq.xcodeproj/project.pbxproj" \
  "$repo_root/apple/App/Logseq.xcconfig"; then
  die "the Apple project still invokes Skip"
fi

manifest="$repo_root/android/app/src/main/AndroidManifest.xml"
shortcuts="$repo_root/android/app/src/main/res/xml/shortcuts.xml"
widgets="$repo_root/android/app/src/main/kotlin/com/logseq/logseq/AndroidWidgets.kt"

grep -Fq 'android.app.shortcuts' "$manifest" \
  || die "Android manifest lost app shortcuts"
grep -Fq '.TodayJournalWidgetProvider' "$manifest" \
  || die "Android manifest lost the journal widget"
grep -Fq '.CaptureWidgetProvider' "$manifest" \
  || die "Android manifest lost the capture widget"
grep -Fq 'logseq://capture' "$shortcuts" \
  || die "Android shortcuts lost Capture"
grep -Fq 'logseq://journal' "$shortcuts" \
  || die "Android shortcuts lost Journal"
grep -Fq 'class TodayJournalWidgetProvider' "$widgets" \
  || die "Android journal widget provider is missing"
grep -Fq 'class CaptureWidgetProvider' "$widgets" \
  || die "Android capture widget provider is missing"

echo "No-Skip Android contract passed"
