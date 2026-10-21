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
- [x] YouTube timestamps: retain playback start state per video within the rendered document, show timestamps as actions, and update the corresponding existing player.
  Touch OutlinerBlockContent.kt and rich-content tests.
  Verify visible timestamp actions, matching-player seeking, unrelated-player isolation and invalid data fallback.
- [x] Shift+Enter: preserve a newline inside the edited block while ordinary Enter keeps its split behavior.
  Touch OutlinerEditor.kt and editor instrumentation tests.
  Verify insertion/replacement with Unicode selections, actual keyboard modifiers, regular Enter and composition handling.
- [x] Background sync: register persistent network-constrained system work and reuse the real authenticated core sync path without creating a second UI runtime.
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
- YouTube timestamps: two new rich-content cases reproduce the old duplicate-player/unreadable timestamp behavior. Ten rich-content cases now pass, including a separate timestamp block seeking the existing matching native WebView, retaining both WebView instances and leaving the other video URL unchanged. Invalid timestamps remain readable and disabled.
- Shift+Enter: two real modified-key tests first reproduce structural splits, then all three keyboard cases pass for append, reversed Unicode selection replacement and ordinary Enter/multiline paste. Combined rich-content, keyboard and native editor toolbar suite: 20 passed.
- Background sync: six installed instrumentation cases pass with real encrypted token storage, real native core calls, a real local WebSocket server and a prepared plaintext QA graph. The received server cursor advances from 0 to 1 in the graph checkpoint. Network rejection retries, cancellation releases the core, absent sessions skip, and a held foreground lease blocks cold session replacement.
- Background auth regression: a real refused refresh connection first reproduced credential loss. Transient failures and cancellation now retain refresh credentials; explicit invalid-grant/token responses still clear rejected credentials.
- Cached encrypted graph bootstrap: a boundary regression first fails for an unlocked cached graph, then passes; locked graphs continue to await unlock. This is separate from the plaintext native network integration test.
- System integration: a forced JobScheduler execution binds the real JobService while MainActivity is editing. The composer draft remains unchanged. An OS timeout stops the job, returns it to waiting, and the temporary QA draft suffix is removed.
- Final combined installed suite: 35 passed in 63.766 seconds. JVM suite: 58 passed, zero failures/errors/skips. Shared core: 900 passed after the gallery path correction.
- Reproducible background flow: `scripts/test-android-background-sync.sh emulator-5556` clones only the dedicated QA graph into temporary storage, removes pending operations/errors in that clone, seeds a current journal and runs the six native integration cases. The flow itself passed. It rejects physical device serials and leaves the source graph database unchanged.

## Delivered commits

| Feature | Commit |
| --- | --- |
| Existing Android work checkpoint | 88feb9f |
| iOS confirmation capped at 1.5 seconds | 474d9d6 |
| Image gallery and imported sibling cache paths | 227b174 |
| Incoming audio/video/document shares | f289c63 |
| Unified M3 gallery presentation | 9964f15 |
| Recording shortcut, widget action and Quick Settings tile | dd44309 |
| Existing-player YouTube timestamp actions | d6776fc |
| Shift+Enter newline within a block | f531f4f |
| Persistent native system background sync | This final feature commit |

Android controls added by this plan use Material 3 components; widgets, shortcuts, share sheets and tiles use their native Android system hosts.
Background execution follows Android's network, power and scheduling limits. The minimum periodic interval is 15 minutes, and a locked encrypted graph requires unlocking before it can sync.
No Apple layout or styling changes are included in these feature commits.


## Additional parity pass

Complete four further confirmed gaps in separate commits. Continue using the TDD and emulator workflow above.
No Apple layout changes or paused performance work are included.

- [x] Remote images: use prepareAssetDownload/cacheDownloadedAsset for authorization, graph ownership and decryption; download off the UI thread; show M3 loading and retry controls; open the downloaded file in the gallery.
- [x] Durable incoming shares: persist before delivery, retain stable capture identifiers and attachment bytes across restart, acknowledge only successful core operations.
- [x] Editor settings: apply saved autocorrection/spell-check preferences to the native input connection and verify text and selection survive updates.
- [ ] Graph progress: show real download/decode/import/open stages and native import record counts in an M3 progress presentation; dismiss on success/failure and reject stale callbacks.

Remote-image verification: three JVM cases pass for cached access, actual HTTP failure followed by retry with byte-exact caching, and graph-change rejection with temporary-file cleanup. The installed emulator suite passes 15 cases: remote retry/preview, rich content and gallery gestures/actions. Tests were observed failing before implementation.

Durable-share verification: both restart/failure and cancellation/attachment-survival tests first timed out against the in-memory queue, then pass on JVM and the installed emulator. Four installed cases pass with existing MIME/file-import coverage. Shares and attachment bytes are atomically staged under filesDir, stable identifiers survive replay, delivery stays ordered, activity recreation retains the intent token, and only successful graph handling acknowledges the entry. Disk work runs on Dispatchers.IO; lifecycle cancellation retains the queue without reporting an import error.

Editor-setting verification: the native EditorInfo regression first showed AUTO_CORRECT still enabled after saving false. Five keyboard cases and seven toolbar cases now pass on the emulator, including actual input flags, preference changes with an existing selection, Unicode replacement, multiline input and sentence capitalization. The remembered input interceptor restarts only when settings change. Android TYPE_TEXT_FLAG_NO_SUGGESTIONS overrides automatic correction; disabling spelling suggestions follows that native rule. Reference: https://developer.android.com/reference/android/text/InputType#TYPE_TEXT_FLAG_NO_SUGGESTIONS .
