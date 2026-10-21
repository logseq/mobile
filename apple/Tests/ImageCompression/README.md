# Image import compression checks

The app's photo picker, embedded picker, camera and file picker converge on
`LGAssetImporter`. The share extension and App Group stager use the same
`LGImageCompression` policy before recording size and SHA-256.

- JPEG larger than 512 KiB: longest edge at most 2560 pixels, JPEG quality 0.90.
  Replace the bytes only when the result is at least 10% smaller. Never upscale.
- Apply all eight EXIF orientation transforms before encoding an upright image.
- Preserve PNG screenshots, alpha, GIF/APNG animation, HEIC, RAW, HDR auxiliary
  images and other formats byte for byte. Avoid downscaling long scans/panoramas
  with an aspect ratio above 3:1. Reject oversized dimensions before decoding.
- PDF, Markdown, audio and other documents bypass image processing.
- Correct a picker's filename/MIME mismatch using the actual image format.
  Every import gets a unique path, including imports with identical filenames.
- Compression runs on the import worker rather than the app's main actor.
  Image I/O decodes JPEG directly to the target resolution.

The existing Logseq master camera path (`frontend/mobile/camera.cljs`) defaults
to quality 80 and returns JPEG. Its journal insertion uses the same asset upload
path. This native policy uses quality 90 and keeps screenshots and formats with
additional semantics intact; it does not change display thumbnails or sync.

Run on macOS without XCTest or SwiftPM:

```sh
bash scripts/test-image-compression.sh _build/image-compression-evidence
python3 scripts/test-ios-share-providers.py
```

The first command tests the actual importer, App Group stager/importer and codec.
It generates repeatable textured images, text screenshots, alpha and animations.
It optionally uses the macOS Sonoma Horizon landscape when installed locally.
No personal photo or system wallpaper is checked into this repository.
The second command exercises real iOS item providers, including file and data
representations, UIImage orientation, large JPEG compression, queueing and
checksum-validated import, in an isolated simulator test app.

Validation on 2026-10-21 (decimal bytes):

| Fixture | Before | After | Reduction | JPEG PSNR |
| --- | ---: | ---: | ---: | ---: |
| Textured 4032 × 3024 JPEG | 8,790,779 | 1,220,434 | 86.1% | 44.18 dB |
| Sonoma 3840 × 2160 landscape JPEG | 5,905,442 | 1,184,826 | 79.9% | 40.08 dB |
| Text screenshot / transparent PNG / animation / HEIC | Original | Identical bytes | 0% | Lossless |

PSNR compares decoded output against Image I/O's upright 2560-pixel reference,
so it measures encoding error separately from the intentional photo downscale.
The regression floor is 35 dB. Output sizes can vary between system encoders.
The generated landscape and screenshot were also inspected visually.
