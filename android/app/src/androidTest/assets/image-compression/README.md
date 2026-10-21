# Android image import compression

Photos, documents and shared URIs pass through `AndroidAssetImporter.importDocument`.
Camera capture and these URI imports finalize through `importedFile`, which calls
`AndroidImageCompression` once before reading final size, MIME and SHA-256.
Only staged application-owned files are replaced; provider originals remain intact.

## Policy

- JPEG larger than 512 KiB: longest edge at most 2560 pixels, quality 90. Keep the
  result only when it saves at least 10%; never upscale.
- Normalize all eight EXIF orientations, including mirrors, while scaling.
- Keep PNG text and transparency, GIF/APNG, HEIC, RAW, HDR/MPF/XMP auxiliary images,
  wide-gamut JPEG and scans/panoramas above 3:1 in their original encoded format.
- Correct JPEG/PNG/GIF/WebP filename and MIME mismatches without changing the
  pixels of preserved formats. Documents and audio bypass image processing.
- Inspect dimensions before decoding. Reject pixel decoding above 100 megapixels.
  Power-of-two decoder sampling bounds the intermediate bitmap allocation.
  Estimated working memory includes decoded/output bitmaps plus 8 MiB overhead;
  the budget is capped at 96 MiB and half the available application heap.
- Serialize compression working sets when multi-item shares import concurrently;
  compute the available budget after acquiring the compression lock.
- Allocation, decoding and output failures retain the original. Discard rejected
  candidates and recycle intermediate bitmaps. A low memory budget skips compression
  instead of reducing the chosen photo quality further.

The dimensions-first sampling follows Android's [large bitmap guidance](https://developer.android.com/topic/performance/graphics/load-bitmap).

## Repeatable checks

With an Android emulator/device connected, use Java 21 and run from `android/`:

```sh
./gradlew :app:connectedDebugAndroidTest :app:testDebugUnitTest :app:compileReleaseKotlin \
  -PlogseqRequireNativeCore=false \
  -Pandroid.testInstrumentationRunnerArguments.class=com.logseq.app.AndroidImageCompressionInstrumentedTest
```

The eleven instrumented tests exercise real Android `BitmapFactory`, `Bitmap`,
`ExifInterface`, JPEG encoding, item-provider/file persistence and FileProvider
camera output. Tests cover:

- Codec PSNR above 35 dB, reductions, small/optimized inputs and repeated preparation.
- Every EXIF orientation, 24-megapixel sampling with a 64 MiB budget, oversized
  dimension headers, a 1 MiB budget and an unwritable output directory.
- Byte-exact text/alpha PNG, real GIF/APNG/HEIC containers, opaque RAW/document data,
  MPF/XMP markers, real Android Ultra HDR gain maps and Display P3 JPEG.
- Photo/file/camera/share routes, final hashes and sizes, original provider bytes,
  MIME mismatches and unique paths for duplicate filenames.

The three small container fixtures were generated with Apple's Image I/O from a
32 × 24 sRGB bitmap: GIF/APNG have two differently colored frames; HEIC has one.
They contain no personal images. Tests do not require a Mac to load these fixtures.

## Validation evidence (2026-10-21)

Android 16 / API 36.1, arm64 emulator, Android system encoder:

| Fixture | Before (bytes) | After (bytes) | Reduction | PSNR |
| --- | ---: | ---: | ---: | ---: |
| Textured photo, 4032 × 3024 → 2560 × 1920 | 7,074,268 | 642,115 | 90.9% | 41.03 dB |
| Sonoma landscape exported to sRGB JPEG, 3840 × 2160 → 2560 × 1440 | 7,162,084 | 784,247 | 89.1% | 38.37 dB |

PSNR uses the decoded source resized by Android to the output dimensions as the
reference, separating JPEG encoding error from intentional photo downscaling.
The landscape is an optional local system-wallpaper fixture, not a bundled asset.
To reproduce that measurement, install the generated APKs, stream the JPEG into
the app's private files directory with `adb shell -T run-as com.logseq.app tee`,
then pass its absolute device path as `-e landscape PATH` to `am instrument`.
Writing an external directory as the shell user does not grant the app access.

All eleven compression tests and the separate Compose adaptive-insets test passed
together (`OK (12 tests)`). The 44 JVM tests, Release Kotlin compile and
`dune build @shared/native/runtest` also passed. No native core build is required
by this instrumented import test, and the Gradle command explicitly skips it.
