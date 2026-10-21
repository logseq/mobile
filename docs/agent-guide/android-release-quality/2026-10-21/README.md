# Android release quality evidence — initial 2026-10-21, continued 2026-10-22

Implementation, emulator verification and the final native recording are complete. This does not establish Redmi performance or production Release readiness. See [the result report](../../005-android-release-quality_report.md) for conclusions and remaining gaps.

## Accepted source and artifacts

- Root build revision: `2ad7d02e`, plus this task's Android workspace changes. Other concurrent Apple/shared-core/editor work is preserved; later workspace HEAD is not the identity of these frozen APKs.
- App LUI pin: `1edf12691bcd78ee65b52355d5c2a35f4194524c`. Equivalent source tree pushed to LUI main as `e33a152120dff61a65217130d9479f0e974fde47`, after `03cc0806`. The diff is one Android backend file, four insertions/one deletion. It adds a retained-kind query and exposes an existing decoded-batch method. No Swift/OCaml/layout/style changes.
- `patch-pipeline/final-frozen-apks.json`: frozen Debug, AndroidTest and unsigned Release checksums. `final-integration-performance/apk.json`: the locally signed final Release and native library checksums. `apks.json` retains historical packages and a clearly named `final-frozen-release` entry.
- Final native build gate: `patch-pipeline/final-build-gate.log`. The earlier incremental packaging failure and successful retry are retained as `native-build-package-failure.log` and `integration-release-success.log`; they are not hidden or counted as a passing first attempt.
- JVM tests: 54 passed, XML under `unit-tests/`. Nine backend contracts also passed on the original pipeline (`patch-pipeline/contracts-nine-original.log`). Functional renderer/accessibility/contrast and measurement RED/GREEN logs remain in this directory.
- Final frozen APK instrumentation: `patch-pipeline/final-frozen-ui.log`, **17 tests passed**. Earlier 23-test runs included the withdrawn layout experiment and do not represent the retained suite. Premature/intermediate logs are not the final integration gate.
- Measurement validity tests: eight; graph seed tests: two; existing shell E2E runner suite passed. LUI's own host-disabled Paparazzi test task is not counted as a pass.

## Accepted measurements

AVD `logseq_release_qa_33`, `emulator-5556`: API33 Google APIs arm64, 1080×2400, density420, 60Hz, four cores, 2048MiB, host GPU, headless, radios disabled. Dataset: 100 journals × eight blocks, no WebViews. The explicitly gated androidTest fixture uses an invented token and a closed localhost endpoint; it does not validate real authentication or sync.

No timing run overlaps this task's compilation, tracing, screenshots or recording. The Mac is shared, so unrelated host work remains a source of variance. Each scroll round uses four downward/four upward 400ms gestures and retains foreground/window state, middle/before/after hierarchy, frame statistics and memory. The driver rejects obstructed, nonmoving or zero-frame scroll samples. The idle 0-frame `4950ms` histogram sentinel is not idle jank.

- `simplified-cpu/`: actual Simpleperf startup/scroll samples. Patch handling/application accounts for 3.53% of sampled process CPU, not all stalls.
- `patch-pipeline/native-patches.json`: actual 50-batch native viewport stream, 8,774,118 bytes. SHA256 `849c3a1969d03a46b9697c2ce9f87a94e698273af5720bdfef1c7584b47b4530`. The original metadata table retained detached history and copied it every batch; the fix removes that duplicate state and the second JSON parse.
- `patch-pipeline/release-before.json`, `release-after.json`, `release-before-2.json`: non-debuggable Release CPU replay of the identical stream/core, six warmups plus 12 samples each. Correct medians from raw samples: 492.38 / 348.09 / 1007.37ms. `summary.json` is authoritative; provisional/debug summaries are historical. About 29% lower in the first pair is pipeline CPU only, not whole-app speed or a cross-device guarantee.
- `patch-ui-before/` and `patch-ui-after/`: controlled same-content Release scrolling, native libraries byte-identical (core SHA `51332dec49f00dcf822f44cbc2536ad25723c45f03c9f8f1f8819c86ff539932`). Original 93/743 janky frames (12.52%); new 59/949 (6.22%). Both renderers already include all rich-content fixes. Only two product Kotlin files differ (`patch-pipeline/controlled-source-differences.json`). The isolated baseline build produced path/build-ID differences in native libraries, so they were replaced with the after APK's libraries, zipaligned and locally signed; checksums are in `patch-ui-after/controlled-apks.json`. Both use reset ART state and normal packaged library profiles with speed-profile compilation.
- `final-integration-performance/`: the final frozen package with rebuilt current native core, SHA `d296f89ec569e49b2c87454cbbb21c766a3d4751efba06f7cb923b5920b021b9`. Three rounds: 11/324, 7/336, 9/333 janky frames; P95 26/23/21ms; P99 73/30/27ms. Total 27/993 (2.72%). All three meet the suggested emulator budget, but this newer core is a separate integration validation and cannot be used to inflate the controlled optimization percentage.

## Final visual evidence

`android-final.png`, `android-final-hierarchy.xml`, `final-demo-after-hierarchy.xml` and `android-final-demo.mp4` come from the final frozen Release. The video is unedited Android `adb shell screenrecord`, H.264 1080×2400, 24.829056 seconds, no audio (`final-demo-metadata.json`). It shows restored rich content, formula/code rendering and bidirectional scrolling. A still and a scrolling frame were visually reviewed. Recording was separate from timing.

## Rejected and historical evidence

The root-menu overlay experiment (`d01cb95c`) is withdrawn, absent from the pinned dependency and not pushed to main. Its extra layout/menu machinery did not justify its complexity. The candidate 2,740-rule app Baseline Profile is archived as `evaluated-baseline-prof.txt`, absent from app build inputs. Six experiment-only tests are archived as text. Normal dependency profiles remain.

API36 system/ART startup ANRs, wrong-foreground/timeout samples, failed demo navigation, provisional microbenchmarks and intermediate integration builds are retained for audit, not combined with accepted API33 measurements. [Historical experiment notes](historical-experiments.md) preserve their original context and superseded status statements.
