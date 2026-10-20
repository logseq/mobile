# Shared Domain Consolidation Implementation Plan

Goal: Remove obsolete Swift application APIs and give OCaml ownership of the remaining shared effect, bootstrap, capture, and editing semantics.

Architecture: OCaml emits complete native service requests and consumes their results through the existing serialized core boundary.
Swift and Kotlin retain native rendering, transient input reconciliation, credentials, HTTP streaming, filesystem access, and operating-system integration.
Do the work directly on main in `/Users/tiensonqin/Codes/projects/logseq-chat` and commit each completed stage separately.

Tech Stack: OCaml 5.5, Dune, LUI, SwiftUI/UIKit, Swift Testing, Kotlin/Jetpack Compose, URLSession and OkHttp.

Related: Builds on `002-ocaml-platform-boundary.md`.

## Problem statement

The first boundary migration removed the platform snapshot reducer, shared sync protocol, retry policy, and autosave decisions.
Obsolete Store wrappers remain, and native hosts still translate core effects into core RPC calls, interpret snapshot bootstrap metadata, assemble shared capture text, and implement a few editor/media semantics.
These rules should have one implementation and behavioral coverage in OCaml.

## Testing Plan

Start with the existing shared native gate and direct Swift model runner.
For each migration, first add all relevant behavior tests and observe the expected failures before implementation.
Use production application/session paths to verify graph mutations, effect completion, failure propagation, capture idempotence, cursor/schema selection, graph switching, and stale download rejection.
Cover transcript insertion with asset creation, malformed metadata, failed import, offline cached graphs, locked encrypted graphs, capture title deduplication, Unicode pair deletion, and media timestamp association.
Keep native transport, IME, caret, Return handoff, share-provider, search, and extension packaging checks.
For deletion-only changes, audit production references and retain meaningful behavior coverage at the actual shared entry points rather than adding tests for absent symbols.

Run these commands from the repository root, serializing all commands that invoke Dune:

```sh
rtk proxy opam exec --switch=5.5.0 -- dune build @shared/native/runtest
rtk proxy python3 scripts/test-swift-model-suite.py
rtk proxy env LOGSEQ_OPAM_SWITCH=5.5.0 scripts/build-mobile-ios-simulator.sh
rtk proxy python3 scripts/test-swift-ui-suite.py
```

Inspect the Android build instructions before running the existing JVM test gate and native arm64 build.
Run the existing native HTTP/WebSocket, snapshot, shared-provider, and editor smoke scripts affected by the final implementation.
Never run `swift test` or XCTest.

NOTE: I will write *all* tests before I add any implementation behavior.

## Stage 1: Remove obsolete Store APIs

1. Audit references in `apple/Sources`, `apple/App`, scripts, and test fixtures before each deletion.
2. Remove production-unreachable Store convenience methods and their private payload/state helpers from `apple/Sources/LogseqModel/ViewModel.swift`.
3. Remove tests that only exercise retired wrappers while retaining or moving meaningful core, queue, and transport coverage to production entry points.
4. Remove unused `OutlinerYouTubeTimestampPolicy.targetURLsByBlockID` from `apple/Sources/Logseq/OutlinerEditing.swift` and its retired-only tests.
5. Remove unreachable branches and passthrough policy helpers where reference analysis proves they add no behavior.
6. Run core, Swift model, and affected UI compilation checks and commit.

## Stage 2: Execute shared core effects in OCaml

1. Add integration cases in `shared/test/logseq` that execute real capture/task/search/navigation/outliner/flashcard effects and inspect real session responses.
2. Include invalid payloads, unknown effects, stable identifiers, transcript child creation, failure propagation, and repeated delivery.
3. Move the semantic mapping currently in `apple/Sources/Logseq/LGEffects.swift` and `android/app/src/main/kotlin/com/logseq/app/runtime/CoreEffectExecutor.kt` to a shared OCaml executor.
4. Use the existing native bridge/RPC boundary for execution rather than adding another platform orchestration layer.
5. Preserve effect identifiers, native result delivery, platform command revisions, draft cleanup, and user-visible error behavior.
6. Keep time and randomness supplied through existing core facilities or explicit host inputs, with deterministic test injection.
7. Make asset and transcript creation one core-owned operation and remove the native second mutation.
8. Run shared and both native executor regressions and commit.

## Stage 3: Consolidate snapshot protocol and bootstrap decisions

1. Add session-level cases for valid/invalid cursor metadata, schema fallback, relative download URLs, cached graph activation, encrypted graphs, force recovery, and late results after graph switches.
2. Move request construction, metadata interpretation, and sequencing from `apple/Sources/LogseqModel/GraphSyncHTTP.swift` and the Android snapshot downloader into shared core commands.
3. Move lifecycle decisions from `apple/Sources/Logseq/LGGraphLifecycle.swift`, `LogseqStore.bootstrapSelectedGraph`, and corresponding Android lifecycle code to the shared session.
4. Preserve progress reporting, native temporary-file ownership, streaming, decompression, token acquisition, cancellation, and background task lifetime.
5. Keep filesystem probing native but report facts to the core instead of interpreting graph state in the host.
6. Run core bootstrap and real native snapshot/first-sync/encrypted-graph regressions and commit.

## Stage 4: Consolidate shared capture semantics

1. Add core behavior cases for text/title/URL combinations, duplicate titles, empty input, Unicode, and deterministic repeated capture IDs.
2. Move canonical note text assembly and deep-link semantics from `apple/Sources/Logseq/SharedCapture.swift` into the core.
3. Keep App Group queue persistence, provider loading, App Intents, file staging, checksums, and OS URL delivery native.
4. Preserve compatibility with already queued shared captures and deliver their stable identifiers unchanged.
5. Run text/photo/screenshot/PDF/Markdown provider and shortcuts regressions and commit.

## Stage 5: Consolidate editor and media semantics

1. Add core editing cases for empty node-reference deletion at valid/invalid UTF-16 ranges, selected text, Unicode, and ordinary backspace.
2. Add markup projection cases for YouTube URLs, timestamp association, explicit targets, and safe embedded-media URLs.
3. Move those rules from `apple/Sources/Logseq/OutlinerEditing.swift` into shared editor/markup projections and make native renderers consume the result.
4. Keep native text reconciliation, IME marked text, caret geometry, Return handoff buffering, view identity, and WebKit presentation.
5. Run shared editor/markup tests and native caret/Return/media regressions and commit.

## Stage 6: Full verification and final audit

1. Run the full shared native, Swift model, Swift UI, and Android JVM gates on the final revision.
2. Build iOS App/Share/Widgets/Shortcuts and Android arm64 native core.
3. Run affected HTTP/WebSocket, snapshot, capture/provider, search, and editor integration smoke checks.
4. Review the diff for compatibility, duplicated domain rules, accidental public API retention, and quadratic sequence handling.
5. Record exact results, remaining native responsibilities, and any concrete environment limitation here.
6. Commit the final verification documentation and leave main clean.

## Progress

| Stage | Status | Evidence |
| --- | --- | --- |
| Plan | Complete | Current main is the implementation workspace |
| Obsolete APIs | Complete | Removed unused send/search/navigation/flashcard/status wrappers and payloads; preserved serialization, main-actor responsiveness, durable response and transport tests through production capture and graph entry points; 56 model tests pass |
| Core effects | Complete | Shared executeEffect dispatcher replaces Swift/Kotlin mappings; transcript persistence/projection and binary-upload activation covered; 817 core, 109 Swift UI, 42 Android JVM tests pass |
| Bootstrap | Complete | Core owns bootstrap/cache/lock/sync eligibility and snapshot protocol; generations reject stale same-graph downloads; 824 core, 63 model, 109 UI and 41 Android tests plus 12 actual HTTP cases pass |
| Shared capture | Complete | Shared canonicalization, idempotent IDs and deep-link routing; raw metadata queue reads legacy entries; late Android ASR results become shared effects; 828 core, 105 UI, 40 Android tests and real text/photo/screenshot/PDF/Markdown provider checks pass |
| Editor/media | Complete | Core projects validated media URLs, embed requests and timestamp targets; core declares synchronous input rules consumed by native IME/caret adapters; 832 core, 63 model, 102 UI and 41 Android JVM tests pass |
| Final verification | Complete | 832 core, 56 model, 102 UI, 41 Android tests; both native builds, transport/provider/bootstrap/editor/search integrations pass |

## Testing Details

Tests assert persisted graph state, real outgoing service requests, canonical projected markup, and observable native interaction.
Tests must not merely assert copied JSON assembly or mock call counts.
Retired convenience-method tests can be removed only after their meaningful behavior is covered through the live core/runtime entry points.

## Implementation Details

Android speech recognition remains asynchronous.
A transcript already available at capture time is staged atomically with its asset.
A later recognition result is a separate native service event; the core creates its child once without delaying the original audio capture.


- Keep `.ml` and `.mli` changes together.
- Serialize all Dune operations, including mobile wrapper builds.
- Keep network and timer waits outside the core executor.
- Scope asynchronous work to graph/generation identifiers.
- Preserve persisted queue, graph, checkpoint, and wire compatibility.
- Keep Swift/Kotlin OS adapters narrow and explicit.
- Commit each major stage after its relevant checks pass.
- Record deviations with evidence in this document.
- Do not install or publish a new build as part of this source consolidation unless requested.

## Boundary audit

The remaining Swift is responsible for native rendering and OS integration: UIKit/SwiftUI view identity, keyboard/IME state, caret geometry, Return handoff buffering, WebKit/AVPlayer presentation, authentication/keychain access, native HTTP/WebSocket streaming, file staging, background task lifetime, App Group queue storage, share providers, widgets and App Intents.
These responsibilities still require native adapters and should stay in Swift.

The core now owns application effect translation, graph bootstrap and sync eligibility, stale download generations, snapshot protocol metadata, canonical shared text and deep links, asset/transcript mutations, media URL normalization and timestamp association.
Editor syntax rules are declared by the core and applied synchronously by a generic native UTF-16 adapter; waiting for an asynchronous core response inside UIKit or Compose backspace handling would break IME and caret timing.
Legacy queue entries, pending asset intents without transcripts, and additive markup fields remain decodable.
The legacy YouTube target wire property remains for compatibility, with no native domain interpretation.
The unused Swift built-in task-status list/choice merger and identity-only pending-pump helper have also been removed.

The final deletion pass removed seven wrapper/passthrough-only tests; meaningful scheduler, nonblocking transport and durable UI publication cases now exercise production capture/graph adapters.
Actual shared-core tests cover search semantics and journal pagination.
The native integration fixture opens a fresh graph before exercising mutations, matching production startup; opening only the catalog is not sufficient.


## Verification record

Verified on 2026-10-21, directly on main.

| Check | Result |
| --- | --- |
| Shared native gate, `dune build @shared/native/runtest` | 832 tests pass; final gate rechecked successfully |
| `scripts/test-swift-model-suite.py` | 56 tests in 5 suites pass |
| `scripts/test-swift-ui-suite.py` | 102 tests in 11 suites pass |
| Android `:app:testDebugUnitTest -PlogseqRequireNativeCore=false` | 41 tests pass, no failures/errors/skips |
| iOS simulator build | Main app, Share Extension, Widgets and four Shortcuts packaged and verified |
| Android native arm64 build | `liblogseq_core.so` built successfully |
| `scripts/test-ios-shared-domain.py` | Real graph creation/import, capture/task/transcript persistence across reopen, and actual LUI-issued UTF-16 input policy pass |
| `scripts/test-ios-snapshot-download.py` | 12 real HTTP cases pass, including malformed cursor and layered/corrupt gzip |
| `scripts/test-ios-sync-commands.py` | Actual socket sends core bytes and returns opaque frames with generation |
| `scripts/test-ios-sync-recovery.py` | Six close/failure/cancellation modes pass |
| `scripts/test-ios-first-sync-graph.py` | Cold launch uses the configured self-hosted server |
| `scripts/test-ios-encrypted-graph-setup.py` | Native account/graph keys and WebCrypto interoperability pass |
| `scripts/test-ios-share-providers.py` | Actual text/photo/screenshot/PDF/Markdown provider, queue and import checks pass |
| `scripts/test-ios-install-regressions.py` | Both checks pass |
| `scripts/test-ios-device-scripts.sh` | Passes with isolated local configuration and current build expectations |
| `scripts/test-ios-native-interactions.py` | 12 caret comparisons, rapid Return/Shift+Enter, delayed caret acknowledgements, core autosave and three search presentation/dismissal cycles pass |

The native Return fixture originally used a nested synchronous RunLoop, which prevented its queued model acknowledgement from running inside the async app test host.
It now awaits the event loop; rapid Enter/Shift+Enter typing and delayed caret acknowledgements pass without changing product input behavior.
Device-script checks also referenced a removed production-build restriction and sourced developer signing defaults; those tests now inspect current build settings and isolate configuration.

The final native search check exposed an existing iOS 26 search-field relocation: UIKit borrowed the already focused search field into the toolbar, causing two focus acquisitions and one focus loss during each opening.
Sampling showed `UISearchController` borrowing the field and triggering keyboard relayout.
The iOS 26 renderer now embeds one `UISearchTextField` directly and keeps pending native typing until matching core acknowledgements arrive.
New stable-focus and delayed Unicode typing assertions fail against the prior renderer and pass against the new one.
Visual inspection also caught an empty-content sizing issue; the search surface now fills its viewport, and a geometric check verifies the input stays at the bottom above the keyboard.
The final simulator screenshot was visually checked at `/tmp/logseq-consolidation-search.png`.
The fixture separately exercises a plain UIKit text field to account for system keyboard initialization before applying the unchanged 0.8-second first-search and 0.45-second reopening limits; it does not preload the keyboard in production.
The final verified search run took 185/62/61 ms, with one focus acquisition and no intermediate focus loss in each cycle.

Compared with the starting revision `972f784`, production Swift changed by +325/-1508 lines (net -1183).
No XCTest invocation, physical-device installation, TestFlight submission, or Android emulator run is part of this consolidation.

---
