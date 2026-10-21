> Historical record only. Statements below describe superseded candidates and intermediate gates; they are not the accepted final state. Use README.md and the result report for final conclusions.

> Current decision: the root-menu overlay is WITHDRAWN after the user required no extra complexity and unchanged iOS layout/styling. The app and duniverse/lui are back on cd7c7b44. All directories named api33-final/api33-after below refer to historical candidates, not the accepted app. Performance acceptance remains open.

# Android release quality evidence — 2026-10-21

The controlled renderer comparison uses the same original native core in both APKs.
AVD: logseq_android_36, API 36.1, arm64, 1080×2400, 60 Hz, four cores, 3072 MiB RAM, host GPU, headless.
This differs from the earlier QA report’s 2048 MiB configuration; do not combine their metrics.

The fixture is 100 journals × 8 blocks, without WebViews. It is restored to the canonical named graph folder.
Authentication uses an explicitly gated instrumentation fixture with an invented offline token and closed localhost endpoint.
This exercises production UI/storage but does not test real sign-in or sync.
Gradle connected tests remove the app afterward; prepare the offline fixture only after those tests finish.
AndroidOfflineQaFixture runs only with `-e installOfflineFixture true`, checks the dedicated graph ID and confines the endpoint to localhost.

`before/` and `before-3gb/` are INVALID setup attempts: Activity Manager launch timeout / system ANR or wrong foreground, rejected by the driver.
`before-valid/` was rejected by a measurement-tool issue: API 36 exposes current focus under `dumpsys window displays`, not `windows`; a new regression covers it.
`before-valid-v2/` is the original Release renderer after fixture restoration, with packaged library Baseline Profiles installed and speed-profile compilation.
No performance measurement is taken while this task’s Gradle builds are running.
Raw frame statistics, foreground window, middle/before/after UI trees and memory are retained per run.
A hierarchy dump occurs after the fourth gesture to prove list movement; the same driver is used on both sides.

RED/GREEN test logs preserve actual failing behavior and subsequent passing tests.
The added dependencies carry their upstream notices under android/app/src/main/assets/licenses.

`before-clean/` repeats the original renderer with both ART profiles cleared, then installs only its packaged library profile and compiles speed-profile. `after-no-profile/` uses the same reset/install/compile sequence with the renderer fixes and offline math/code helpers. The packaged app-specific profile will be evaluated separately.
`apks.json` records APK sizes/checksums and matching core/JNI checksums for the controlled comparison.

The evaluated app Baseline Profile (NOT shipped) contains 2,740 observed owner-filtered rules from production offline startup and journal scrolling. It includes app/LUI, AndroidComposeView, and the exercised math/highlight engines. It does not use a wildcard to compile every app method. Regenerate after dependency/compiler changes using the official manual collection flow: install an unminified non-debuggable Release, broadcast SKIP_FILE (EXTRA_SKIP_FILE_OPERATION=WRITE_SKIP_FILE), compile verify, clear app profiles, exercise startup/scroll, SAVE_PROFILE, force-stop, `pm dump-profiles --dump-classes-and-methods com.logseq.app`, then pull `/data/misc/profman/com.logseq.app-primary.prof.txt`. Filter by the declaring owner in each ART rule to the same packages and write `android/app/src/main/baseline-prof.txt`. Build again and verify INSTALL_PROFILE returns 1, compile speed-profile, and inspect the installed dexopt state.

Reference: https://developer.android.com/topic/performance/baselineprofiles/manually-create-measure

## Accepted comparison

API 36 attempts above remain diagnostic history. Repeated system/ART startup ANRs made that environment unsuitable for the final comparison; they are not application ANRs.

Final controlled AVD: `logseq_release_qa_33`, serial `emulator-5556`, API 33 Google APIs arm64, 1080×2400, density 420, 60 Hz, four cores, 2048 MiB RAM, host GPU, headless, radios disabled. Builds and this task's iOS simulator were stopped during timing. Offline graph/auth setup is the same as above. Other host applications were not terminated, so absolute timings still reflect a shared Mac.

- `api33-before/`: original Release; compile --reset, packaged library INSTALL_PROFILE, speed-profile. 33/986 janky frames (3.35%).
- `api33-after/`: renderer and root-menu overlay with the candidate app profile. 33/971 (3.40%). This candidate is not shipped.
- `api33-final/`: accepted renderer/root-menu implementation without the candidate app profile. 33/939 (3.51%).

Each directory preserves setup, all three scroll rounds, app foreground and actual list movement, idle/startup logs, memory and separate 12-second Perfetto captures. The before/after content differs because the fix restores missing text and lays out real formula/code content; gestures and stored graph are identical, not pixel-identical workloads. No statistically established jank improvement is claimed.

`evaluated-baseline-prof.txt` preserves the rejected candidate, not an active build input. The final app uses normal dependency-provided profiles. Do not attribute the profile candidate's trace results to the accepted artifact.

Withdrawn LUI experiment: https://github.com/logseq/lui/commit/d01cb95cb0de3bdd2710093ce9b0ed739cc00a18 ; `logseq.opam` no longer pins this commit. Android-only Kotlin changes leave the Apple package revision unchanged.

## Integration build

The final integration build uses root revision `a616c08f60101e95b55e8a8da36abfd8a53eeaa3` plus this task's working changes. Native core was rebuilt rather than skipped. Debug, AndroidTest and Release assembled successfully; all 23 instrumentation tests passed again with this rebuilt core (`final-integration-instrumentation.log`). The controlled comparisons intentionally retain the original core; their measurements must not be relabelled as integration-build performance. `apks.json` records both.

The first demo attempt is excluded: after the date-heading tap, Back left the app, so subsequent coordinates did not reach Settings. Its files have the `demo-attempt-` prefix and are not a Settings pass.

`api33-renderer-only/` isolates restored rich content with the original LUI hierarchy: 73/797 janky frames (9.16%), strongly affected by its second-round outlier. This does not establish a stable speedup for any candidate.

Accepted simplified build: `simplified-integration-build.log` and `simplified-integration-instrumentation.log` show successful Debug/AndroidTest/Release assembly and 17 passing retained tests after restoring LUI cd7c7b44. `apks.json` -> `simplified-integration` records the locally signed APK. Other work in the shared checkout continues to modify core/Apple files; this task does not own or revert those changes.

`android-after-demo.mp4` is the accepted simplified integration APK's native `adb shell screenrecord` output, unedited, 1080×2400 H.264, 19.787756 seconds, no audio. It focuses on restored rich content and bidirectional scrolling. `android-after.png` and `demo-after-hierarchy.xml` verify the production journal UI. Recording is separate from timing.

`api33-profile-only/`: corrected renderer and original LUI with the candidate app profile; 86/799 janky frames (10.76%), no stable benefit. The candidate remains rejected. `simplified-trace/` captures the accepted renderer/original-LUI integration build separately; it is not a timing run from the original binary-controlled pair.
