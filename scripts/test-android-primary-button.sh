#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

command -v adb >/dev/null 2>&1 || die "adb is not installed"
command -v swift >/dev/null 2>&1 || die "Swift is not installed"
command -v rg >/dev/null 2>&1 || die "rg is not installed"

device=${ANDROID_SERIAL:-}
if [[ -z $device ]]; then
  device=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
fi
[[ -n $device ]] || die "no online Android emulator or device was found"

xml_file=${LOGSEQ_ANDROID_UI_XML:-}
png_file=${LOGSEQ_ANDROID_SCREENSHOT:-}
if [[ -n $xml_file || -n $png_file ]]; then
  [[ -f $xml_file && -f $png_file ]] \
    || die "LOGSEQ_ANDROID_UI_XML and LOGSEQ_ANDROID_SCREENSHOT must both exist"
else
  xml_file=$(mktemp "${TMPDIR:-/tmp}/logseq-android-primary.xml.XXXXXX")
  png_file=$(mktemp "${TMPDIR:-/tmp}/logseq-android-primary.png.XXXXXX")
  remote_xml=/sdcard/logseq-primary.xml
  remote_png=/sdcard/logseq-primary.png
  trap 'rm -f "$xml_file" "$png_file"' EXIT

  adb -s "$device" shell uiautomator dump "$remote_xml" >/dev/null
  adb -s "$device" pull "$remote_xml" "$xml_file" >/dev/null
  adb -s "$device" shell screencap -p "$remote_png"
  adb -s "$device" pull "$remote_png" "$png_file" >/dev/null
fi

button_node=$(rg -o 'resource-id="button.sign-in"[^>]*bounds="\[[^"]+' "$xml_file")
[[ -n $button_node ]] || die "hosted sign-in button was not found in the Android UI tree"
bounds=$(sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\].*/\1 \2 \3 \4/' <<<"$button_node")
read -r left top right bottom <<<"$bounds"

screen_node=$(rg -o 'resource-id="screen.authentication"[^>]*bounds="\[[^"]+' "$xml_file")
[[ -n $screen_node ]] || die "authentication screen was not found in the Android UI tree"
screen_bounds=$(sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\].*/\1 \2 \3 \4/' <<<"$screen_node")
read -r _ screen_top _ screen_bottom <<<"$screen_bounds"

screen_height=$((screen_bottom - screen_top))
button_center_y=$(((top + bottom) / 2))
minimum_center_y=$((screen_top + screen_height * 35 / 100))
maximum_center_y=$((screen_top + screen_height * 70 / 100))
if (( button_center_y < minimum_center_y || button_center_y > maximum_center_y )); then
  die "hosted sign-in button is outside the centered authentication region (button center $button_center_y, expected $minimum_center_y...$maximum_center_y)"
fi

swift -e '
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 6,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let left = Int(CommandLine.arguments[2]),
      let top = Int(CommandLine.arguments[3]),
      let right = Int(CommandLine.arguments[4]),
      let bottom = Int(CommandLine.arguments[5])
else { fail("could not load the Android screenshot or button bounds") }

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("could not allocate screenshot bitmap") }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func colorAt(x: Int, yFromTop: Int) -> (red: Double, green: Double, blue: Double)? {
    guard x >= 0, x < width, yFromTop >= 0, yFromTop < height else { return nil }
    let offset = (yFromTop * width + x) * 4
    return (
        red: Double(pixels[offset]) / 255.0,
        green: Double(pixels[offset + 1]) / 255.0,
        blue: Double(pixels[offset + 2]) / 255.0
    )
}

guard let background = colorAt(x: max(1, left / 2), yFromTop: (top + bottom) / 2)
else { fail("could not sample the Android screen background") }

var changed = 0
var sampled = 0
for y in stride(from: top + 6, to: bottom - 6, by: 3) {
    for x in stride(from: left + 6, to: right - 6, by: 3) {
        guard let color = colorAt(x: x, yFromTop: y) else { continue }
        let distance = abs(color.red - background.red)
            + abs(color.green - background.green)
            + abs(color.blue - background.blue)
        if distance > 0.20 { changed += 1 }
        sampled += 1
    }
}

guard sampled > 0 else { fail("the hosted sign-in button had no sampleable area") }
let changedRatio = Double(changed) / Double(sampled)
guard changedRatio >= 0.30 else {
    fail(String(format: "hosted sign-in button is not materially filled (changed ratio %.3f)", changedRatio))
}
print(String(format: "ok - Android hosted sign-in button is materially filled (changed ratio %.3f)", changedRatio))
' "$png_file" "$left" "$top" "$right" "$bottom"

echo "ok - Android authentication actions are vertically centered"
