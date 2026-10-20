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
| Obsolete APIs | In progress | Removed 269 production Swift lines and 434 retired-wrapper test lines; core baseline, 66 model and 125 UI tests pass; remaining send/search wrappers await live executor coverage |
| Core effects | Complete | Shared executeEffect dispatcher replaces Swift/Kotlin mappings; transcript persistence/projection and binary-upload activation covered; 817 core, 109 Swift UI, 42 Android JVM tests pass |
| Bootstrap | Complete | Core owns bootstrap/cache/lock/sync eligibility and snapshot protocol; generations reject stale same-graph downloads; 824 core, 63 model, 109 UI and 41 Android tests plus 12 actual HTTP cases pass |
| Shared capture | Complete | Shared canonicalization, idempotent IDs and deep-link routing; raw metadata queue reads legacy entries; late Android ASR results become shared effects; 828 core, 105 UI, 40 Android tests and real text/photo/screenshot/PDF/Markdown provider checks pass |
| Editor/media | Complete | Core projects validated media URLs, embed requests and timestamp targets; core declares synchronous input rules consumed by native IME/caret adapters; 832 core, 63 model, 102 UI and 41 Android JVM tests pass |
| Final verification | Pending | Full gates and native builds |

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

## Question

No user input is required to begin.
The user authorized execution directly on main and separate commits for each major change.

---
