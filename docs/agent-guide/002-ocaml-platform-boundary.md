# OCaml Platform Boundary Implementation Plan

Goal: Give OCaml sole ownership of shared application and sync decisions while Swift and Kotlin execute native services and render LUI projections.

Architecture: The existing OCaml application model, session, and pending-operation interpreter remain authoritative.
Platform adapters execute explicit byte-oriented requests, socket commands, timer commands, and native presentation requests.
The migration preserves current storage and wire compatibility and removes obsolete platform projections after their remaining callers are replaced.

Tech Stack: OCaml 5.5, Dune, LUI, Swift 6, SwiftUI/UIKit, Kotlin, Jetpack Compose, URLSession and OkHttp.

Related: Builds on `001-lg-lui-rewrite.md`, `../adr/001-real-time-graph-sync.md`, and `../adr/002-mobile-outliner-mode.md`.

## Problem statement

Swift currently combines native services with WebSocket protocol handling, graph bootstrap decisions, retry policy, editor save policy, and a second application snapshot reducer.
Android contains corresponding protocol and scheduling implementations.
The same app behavior can therefore diverge by platform even though the application model and graph operations already live in OCaml.

Stages 1–3 ran in `/Users/tiensonqin/Codes/projects/logseq-chat-ocaml-boundary` on branch `logseq/ocaml-platform-boundary`.
The user then requested merging into the latest main and continuing directly on main.
Integration uses `/Users/tiensonqin/Codes/projects/logseq-chat`, whose existing capture/share/rendering work was committed as `3e0b780` before the merge.
Keep that work and run all integration regressions before continuing on main.
Commit each major change separately; do not push unless requested.

## Testing Plan

Use the existing OCaml RPC/session integration harness to exercise the real graph session and resulting transport commands with deterministic time and response events.
Cover initial connection, coalesced remote notifications, multiple pull pages, local pending operations, schema reset, disconnect, reconnect, graph switches, stale responses, offline transitions, cancellation, and snapshot deferral during editing.
Exercise HTTP failure and duplicate-checksum recovery through the real pending pump and verify request identity remains stable after retries.
Exercise editor events through the shared application and session, including IME/transient text, autocomplete, Return and backspace, route changes, save cancellation, and stale timer delivery.
Verify native consumers execute the same shared commands rather than interpreting graph values.
Retain native input reconciliation, caret and layout smoke checks.

Run focused tests before the full `rtk proxy dune build @shared/native/runtest` gate.
Never run `swift test`.
Use Swift build and existing standalone native harnesses for Apple checks.
Run Android compilation and focused Gradle tests when the installed SDK/toolchain supports them.
Serialize all Dune invocations and scripts that invoke Dune.

NOTE: I will write *all* tests before I add any implementation behavior.

## Ownership contract

| Concern | Owner | Platform responsibility |
| --- | --- | --- |
| Graph, editing, navigation and sync state | OCaml | Deliver typed user and OS events |
| WebSocket protocol, cursor and reconnect policy | OCaml | Open/send/receive/close sockets and wait requested delays |
| Pending HTTP decisions and recovery | OCaml | Execute one requested HTTP/upload operation |
| Save timing and autocomplete policy | OCaml | Schedule/cancel a requested timer and return its token |
| Snapshot and outline projection | OCaml | Render patches and retain native view identity |
| IME, local text reconciliation, caret and geometry | Native UI/LUI backend | Own transient interaction state |
| Camera, photo, audio, credential storage and share extensions | Native host | Read/write OS resources and return results |

## Stage 1: Baseline and legacy cleanup

1. Record the base revision and production/test symbol references before deletion.
2. Establish core and native build baselines in the isolated worktree.
3. Remove unused section/preorder projection methods from `apple/Sources/LogseqModel/ViewModel.swift` after proving they have no production callers.
4. Remove unreachable legacy policy groups from `apple/Sources/Logseq/OutlinerEditing.swift` and update tests that only exercise removed APIs.
5. Retain policy helpers reachable through production helpers, native editor reconciliation, focus, text measurement, and active rich-content rendering.
6. Run compilation and the existing behavioral checks.

## Stage 2: Shared WebSocket and graph lifecycle decisions

1. Add integration cases in `shared/test/logseq/rpc_test.ml` for socket events and explicit outgoing commands.
2. Confirm failures occur because the shared session does not yet produce the required commands.
3. Introduce a small typed shared sync driver under `shared/src/logseq/core/`, with a matching `.mli`.
4. Integrate it with `session_types`, `rpc_session`, and the existing `sync_session` cursor and event application boundaries.
5. Publish commands for connect, send, close, wake, snapshot refresh, and pending-sync wake through the existing RPC snapshot boundary.
6. Replace JSON frame interpretation and pull/cursor bookkeeping in Swift `ViewModel.runGraphEventsOnce` and Kotlin `AndroidGraphEventsSync` with command execution and raw event delivery.
7. Move reconnect, snapshot deferral, and graph-generation decisions from `LGGraphLifecycle` and `AndroidGraphLifecycle` into the shared driver.
8. Keep token acquisition, background-task lifetime, URLSession/OkHttp, file streaming, and native cancellation in platform code.
9. Verify graph switches reject stale socket/timer results and no FFI call holds the core worker while waiting for network traffic.

## Stage 3: Shared pending transport recovery

1. Add real pending-pump tests for transport loss, retry exhaustion, duplicate checksum, paginated asset lookup, conflict, and cancellation.
2. Verify the missing shared behavior fails before implementation.
3. Move retry budgets and error interpretation into the OCaml pending transport state. Audit confirmed the current raw PUT upload uses stable asset paths and metadata headers; the old paginated checksum resolver is specific to the unused semantic POST upload. Remove that obsolete native resolver and verify raw-upload conflicts remain failures rather than inventing a successful upload.
4. Preserve operation UUID, transaction identity and expected cursor across retries.
5. Reduce Swift `PendingSyncTransport.swift` and Kotlin `AndroidPendingSync.kt` to one-request executors.
6. Keep path resolution, native streaming, headers, OS transport errors and cancellation in platform adapters.
7. Run pump integration tests and platform transport checks.

## Stage 4: Shared editor save policy

1. Add real application/RPC cases for debounced saves, autocomplete suppression, atomic structure events, route changes and stale timers.
2. Verify the cases fail because scheduling still belongs to the platforms.
3. Make the shared application/session emit generic deadline effects with cancellation/generation tokens.
4. Let Swift and Kotlin execute timer effects without inspecting text, autocomplete or graph state.
5. Remove duplicate save policy from `LGRuntime.swift`, `ViewModel.swift`, `GraphSyncHTTP.swift` and `NativeEffectDrain.kt` as the new path replaces it.
6. Keep native text input and frame-level event coalescing only where it preserves IME/caret behavior, with ordering specified by the shared event contract.
7. Validate Return/backspace, fast typing, completion selection, background save and graph-switch behavior.

## Stage 5: One application projection

1. Trace remaining `LogseqStore.snapshot` consumers and distinguish native presentation data from domain decisions.
2. Add integration checks for partial responses, row splices, deletion, selection, route retention and background sync responses.
3. Expose the needed projection through the existing OCaml/LUI response path and replace domain consumers of Swift merged snapshots.
4. Remove the Swift `mergedSnapshot` domain reducer and redundant state/model helpers after all live callers are migrated.
5. Keep typed platform DTOs and native render caches where they are needed to execute commands without rebuilding UI identity.
6. Verify native rendering does not require a second graph/outline model and confirm Android uses the same projection contract.

## Stage 6: Integration and delivery

1. Run the full OCaml gate and platform compilation checks.
2. Run native editor, navigation, search, share and background-sync regression checks relevant to the touched boundaries.
3. Record measured code removal, remaining platform responsibilities, verification output and any environment limitations in this plan.
4. Reconcile the finished changes into the original workspace, preserving all unrelated and prior feature edits.
5. Re-run checks affected by integration and leave the result reviewable.
6. Commit each major stage separately after validation, as requested by the user.
7. Mark the goal complete only after all required stages have been implemented and verified.

## Progress

| Stage | Status | Evidence |
| --- | --- | --- |
| Plan and isolation | Complete | Worktree based on `ab3ce02`; prior workspace preserved |
| Legacy cleanup | Complete | Removed 26 unreachable type groups and unused section/preorder projection; 604 production Swift lines and 1046 obsolete test lines removed; 776 core tests and LogseqModel build passed |
| Shared sync driver | Complete | 782 core tests, 36 Android JVM tests, Swift model build, real WebSocket command harness and iOS simulator App/extension build passed; snapshot recovery and reconnect commands execute on both platforms |
| Pending recovery | Complete | 789 core tests, 37 Android JVM tests, iOS App/extension build, Swift model build and native retry-delay harness passed; stable request/transaction identity, cleanup, graph switches and Unicode error summaries covered |
| Shared autosave | Complete | 799 core tests, 39 Android tests and native autosave command checks passed; shared idle-save/cancellation/sync effects replace both platform timers. A direct Swift Testing simulator host runs the 126-test UI suite; async fixtures, background cancellation and preservation of operation errors during render were fixed. Legacy Store projection cleanup follows in Stage 5 |
| Single projection | Pending | |
| Integration and verification | In progress | Stages 1–3 merged into latest main (`3e0b780`); 792 core, 39 Android and 104 standalone Swift model tests passed; App/Share/Widgets/Shortcuts build and actual core/native interrupted-upload regression passed; remaining migrations continue on main |

## Testing Details

Protocol tests send real events into the production shared session and assert actual outgoing requests and observable graph state.
Pump tests execute actual operation transitions and replay rather than testing copied platform algorithms.
Autosave tests advance an injected clock and verify committed graph data and cancellation behavior.
Native harnesses exercise production editor and presentation implementations without XCTest.
Deletion-only cleanup is verified with reference auditing and compilation rather than new tests that mirror source structure.

## Implementation Details

- Keep signatures and implementations synchronized.
- Prefer extending existing RPC effects and session ownership over adding a second orchestration runtime.
- Keep all network and timer waits outside the OCaml runtime lock.
- Scope asynchronous events with graph and connection generation identifiers.
- Preserve existing wire and persisted operation formats unless a backward-compatible optional field is sufficient.
- Use vectors or bounded queues for growing operation/event sequences and avoid quadratic list append patterns.
- Preserve platform token handling and credential-store boundaries.
- Recheck source references immediately before deleting code.
- Report checkpoints while continuing within the user-authorized goal.
- Do not include unrelated work in commits or overwrite concurrent changes.

## Question

No user decision is required to start.
Platform-specific APIs and packaging remain native, while shared application behavior moves to OCaml.
Any unsupported build environment will be recorded with the exact failed command and independent validation completed where possible.

---
