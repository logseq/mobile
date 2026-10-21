# Android Functional Parity Implementation Plan

Goal: Complete the six confirmed Android functional gaps, with one tested commit per feature.

Architecture: Reuse the shared OCaml graph operations and the existing Android runtime, attachment storage, presentation host and native Compose controls.
Keep Apple layout unchanged. The separately requested iOS capture confirmation duration is capped at 1.5 seconds (474d9d6).
Do not resume the paused performance or component migration work.

Tech Stack: Kotlin, Jetpack Compose, Android system intents and scheduling, existing OCaml RPC.

Related: Builds on 006-android-m3-device-quality.md and the functional comparison in this chat.

## Problem statement

The current Android UI implements the principal graph workflows but lacks the iOS image gallery, complete incoming attachment sharing, quick recording entries, coordinated YouTube seeking, Shift+Enter within a block and persistent background sync scheduling.
The existing Android work was committed and pushed first as 88feb9f.
Unrelated Apple changes in this shared checkout are excluded.

## Testing Plan

For each feature, write its happy-path, edge-case and failure tests before implementation.
Observe a genuine behavior failure, implement the smallest change, rerun the focused tests and relevant regressions, inspect the diff, then commit that feature alone.
Use actual Compose gestures, Android intent resolution, real files and system services rather than mock-only assertions.
Use the dedicated emulator graph for any content-changing test.
Never clear or seed the physical phone's user graph.

NOTE: I will write *all* tests before I add any implementation behavior.

## Ordered commits

- [x] Image gallery: add paging, pinch/pan, current-image save/share and Back dismissal in Android's existing presentation host.
  Touch Android runtime/extension registration, a dedicated gallery composable and image storage helpers.
  Verify the selected initial image, real swipe/pinch, current-page action paths, missing images and actual MediaStore writes.
- [x] Incoming shares: register audio, video, PDF, Markdown and generic files, preserving text/images and multiple attachments.
  Touch AndroidManifest.xml and Android app-entry tests.
  Verify package-manager resolution and actual URI import, including text plus attachments and cancellation/error handling.
- [x] Quick recording: register the audio deep link and recording actions for launcher shortcuts, capture widget and a native Quick Settings tile.
  Touch AndroidManifest.xml, shortcuts.xml, AndroidWidgets.kt and the existing entry handler.
  Verify cold-entry routing, one recording request, existing capture/journal routes and OS shortcut/widget/tile declarations.
- [ ] YouTube timestamps: retain playback start state per video within the rendered document, show timestamps as actions, and update the corresponding existing player.
  Touch OutlinerBlockContent.kt and rich-content tests.
  Verify visible timestamp actions, matching-player seeking, unrelated-player isolation and invalid data fallback.
- [ ] Shift+Enter: preserve a newline inside the edited block while ordinary Enter keeps its split behavior.
  Touch OutlinerEditor.kt and editor instrumentation tests.
  Verify insertion/replacement with Unicode selections, actual keyboard modifiers, regular Enter and composition handling.
- [ ] Background sync: register persistent network-constrained system work and reuse the real authenticated core sync path without creating a second UI runtime.
  Touch the application/scheduler/worker and existing authentication/core serialization boundaries.
  Verify unique scheduling, no-session/no-graph behavior, actual native sync against a local endpoint, retry/cancellation and coexistence with the foreground runtime.

## Testing Details

Use `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest --max-workers=2 --no-parallel '-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=1g'` as applicable.
Run the focused installed instrumentation class on emulator-5556 and inspect its test count and failures.
If shared OCaml changes are necessary, serialize `opam exec --switch=5.5.0 -- dune build @shared/native/runtest` with native mobile builds.
Do not run swift test or edit Dune files.
Record actual commands/results and feature commit hashes below as work completes.

## Implementation Details

- Use Android platform APIs and current existing dependencies before adding a library.
- Keep image and attachment paths under the existing graph/cache/FileProvider rules.
- Share or save the currently selected image rather than the initially opened image.
- Preserve normal capture, journal, text input and asset behavior.
- Keep network sync serialized with the existing native core.
- Commit only feature-owned files and leave concurrent Apple edits untouched.
- Push the resulting commits to main using the existing authorized remote.

## Question

No user action is required for the emulator checks.
Background work follows Android's network, power and scheduling restrictions; it does not promise an exact execution time.

---

## Verification log

- Initial checkpoint: 88feb9f pushed to main; native core gate passed, JVM tests passed, and 14 QA utility tests passed.
- iOS confirmation: 474d9d6 pushed; behavioral RED followed by 900 passing core tests. iOS 1500 ms, Android 2500 ms.
- Gallery: four new instrumentation cases cover swipe, real pinch with pixel changes, unavailable images and byte-exact MediaStore save. Eight rich-content regression cases also pass.
- Gallery entry regression: actual imported siblings exposed missing cache-model paths in the gallery RPC. A real persisted-graph test reproduces the failure; 900 core tests pass after resolving local paths from the existing cache model.
- Gallery installed-app entry check: actual external shares open a four-image gallery, a real swipe advances from 1 / 4 to 2 / 4, and Android Back dismisses it. Screenshot: `/tmp/logseq-gallery-entry.png`. The rebuilt native library includes the core regression fix.
- Gallery feature committed and pushed as 227b174.
- Incoming shares: RED OS resolution for audio, then two instrumentation cases pass across eight MIME types and both send modes. Real FileProvider documents retain their original bytes; missing/empty sources are rejected. An actual implicit PDF share cold-launches MainActivity and imports the exact bytes into the dedicated QA graph.
- M3 gallery follow-up: full-screen native dialog with edge-to-edge system insets, M3 surface/container tokens, TopAppBar and native Save/Share icon actions. All four gallery instrumentation tests pass after the styling change; actual app light-mode capture inspected at `/tmp/logseq-gallery-m3-light.png`.
- Quick recording: three OS integration tests first fail for absent audio route, shortcut, tile and widget action, then pass. Actual emulator Quick Settings tile click cold-opens exactly one existing M3 recording sheet with Stop/Cancel; cancelled without adding a recording to the graph.
