# Mobile Interaction Regressions Implementation Plan

Goal: Fix the reported mobile editing, navigation, clipboard, date, table, and TestFlight failures with reproducible evidence and native regression checks.

Architecture: Keep graph semantics in the shared OCaml core and reuse existing native SwiftUI/UIKit and Compose controls.
Read extension state from its current owner and preserve native view identity across unrelated updates.

Tech Stack: OCaml, DataScript, LUI, SwiftUI, UIKit, Kotlin, Jetpack Compose.

Related: Builds on `012-result-views.md`, `013-node-properties.md`, `014-editor-commands.md`, and `015-native-view-filters.md`.

## Problem statement

The user reports visible movement on entering block editing, unchanged images loading again, severe jitter during keyboard transitions, and flashes during navigation.
They also report unavailable long-press actions in nested navigation and search, multiple copied blocks pasting as one block, and an unavailable date-format preference.
Table cells need separators and typed editing for every property except Name, Created at, and Updated at.
The specified TestFlight crash must be investigated after these interaction problems are resolved.

## Testing Plan

Run core integration tests through actual RPC dispatch, graph transactions, SQLite pending operations, and confirmed sync replay.
Use `apple/Tests/UI/run-simulator-runtime-check.py` for real iOS control geometry, keyboard transitions, image request counts, navigation controllers, and clipboard behavior.
Use Android instrumentation to exercise equivalent selection, editing, clipboard, and date interactions.
Record the failing behavior before each fix, then run the same test after the fix.
Do not run `swift test`.
Serialize Dune and every mobile build wrapper that invokes Dune.

NOTE: I will write *all* tests before I add any implementation behavior.

## Status and order

| Order | Work | Current evidence and next action |
| --- | --- | --- |
| 1 | Editing position and image retention | Native regression reproduced a 135.67pt shift and repeated image requests; retaining hidden placeholder slots and their height passes the same test. |
| 2 | Keyboard jitter and page flashes | Device diagnostics reproduced idle 4–8pt jumps during shell/hydration cycles. Native regression reproduces 16pt drift: previously loaded empty blocks become taller skeletons during refresh. Preserve cached renderability separately from hydration freshness; also retain an editor scrolled beyond its window. Repeated navigation validation remains open. |
| 3 | Composer tags | Native controls are shared with property selection; hashtag moved after attachment and status and installed. Nine graph-backed/shared-host checks now cover sends and recovery, including all graph-switch paths, stale catalog failures, tagged asset retries and removing restored tags. Finish native picker checks. |
| 4 | Trim on leaving editing | Shared RPC tests cover hide, switch, selection, collapse, zoom, Return, autosave, blank content, and failed storage; full core gate passes. |
| 5 | Nested/search long press | The feature branch already contains the destination-toolbar fix from `bb4575f`. Native direct/nested/search selection now traverses the effect boundary, visibly renders the bar and dispatches Copy/Unselect successfully. Complete the remaining Recent/root-path audit and physical gesture check. |
| 6 | Master-compatible clipboard | Eleven graph-backed round-trip cases pass: Markdown/EDN snapshots, collapsed descendants, fresh identities, typed properties/ref remapping, empty/nonempty/parent placement, UTF-16 selection, paragraphs, fenced code, foreign graphs and atomic storage failure. Both iOS and Android native clipboard/selection/rapid-typing/failed-save checks pass. Audit remaining master cases before final delivery. |
| 7 | Date-format preference | Audit master settings and existing formatter support, add persistence and consistent rendering without changing journal identity. |
| 8 | Table borders and editability | Thirty core cases, the complete iOS native query/view flow and all sixteen Android query/editor/property/outliner checks pass. Name/timestamps are read-only; Tags use the shared typed editor. The Android stretch root cause is fixed upstream with a verified Paparazzi geometry snapshot. |
| 9 | TestFlight crash | Read the specified crash, identify the crashed build and symbolicated stack, reproduce its cause, and add a regression check before fixing it. |
| 10 | Delivery | Run final gates, update PRs, and non-destructively install and launch the final build on the user's iPhone. |

## Editing and navigation

1. Keep `apple/Tests/UI/outliner-editor-retention.swift` as a native integration check with multiple journal sections and an uncached image URL protocol.
2. Preserve hidden placeholder layout in `shared/src/logseq/view_rows.ml` and `shared/src/logseq/view_outliner.ml` without exposing a placeholder control while editing.
3. Exercise scrolled long pages, multiline editor handoffs, keyboard dismissal, and guide paths with `apple/Tests/UI/outliner-keyboard-stability.swift`.
4. Exercise real UIKit pushes and pops with `apple/Tests/UI/navigation-content-stability.swift`, including repeated visits to the same UUID.
5. Keep `apple/Sources/Logseq/LGNavigationExtension.swift` coherent by reading depth, child IDs, and bottom presentation state from the live extension model.
6. Verify native search navigation and editor controls with `search-result-navigation.swift`, `search-editor-toolbar.swift`, and `editor-completion.swift`.
7. Audit long-press events through `OutlinerRowExtension.swift`, `shared/src/logseq/core/rpc_session.ml`, and route-specific state projection in `shared/src/logseq/model.ml` before editing that behavior.

## Composer and trim

1. Exercise the existing shared picker in `shared/src/logseq/view_composer.ml` using actual native search, create, Done, Cancel, and chip removal controls.
2. Validate `shared/test/logseq/composer_tag_test.ml` against actual capture, asset upload activation, pending-log restart, and confirmed sync replay.
3. Add recovery tests before adjusting graph changes or failed capture restoration in `shared/src/logseq/model.ml`.
4. Keep `shared/test/logseq/editor_exit_test.ml` as a graph-backed regression suite for edge trimming.
5. Autosave in `shared/src/logseq/core/outliner_state.ml` must preserve draft spaces and caret state while finalization and completed split halves trim their edges.

## Clipboard parity

1. Inspect master in `/tmp/logseq-remove-normal-text/src/main/frontend/handler/editor.cljs` and `handler/paste.cljs`, including custom clipboard payloads and plain-text fallback.
2. Add round-trip integration cases for adjacent roots, descendants, nonadjacent selection, multiline block content, properties, references, and paste at different caret positions.
3. Follow the existing native clipboard bridge in `apple/Sources/Logseq/LogseqApp.swift` and the explicit paste origin in `OutlinerInlineEditor.swift`.
4. Implement parsing and insertion through shared core semantics so Android and iOS share block ordering and hierarchy rules.
5. Verify text copied from other apps still behaves like ordinary text, including text ending in slash, brackets, or a hashtag.

## Dates and tables

1. Inspect master preference persistence and `shared/src/logseq/core/dev_query.ml` formatter support before choosing the mobile representation.
2. Add behavioral tests for changing the date format, restarting the app, existing journal identity, local time, and property/table rendering.
3. Add native table checks for vertical and horizontal separators, horizontal scrolling, sidebar gesture arbitration, and editing every supported property type.
4. Update the shared table and property definitions in `shared/src/logseq/view_query.ml` and `shared/src/logseq/core/result_view.ml` without changing master filter or sort semantics.
5. Reject edits to Name and timestamps at the core boundary as well as in the UI.

## TestFlight crash

Investigate `https://appstoreconnect.apple.com/m/teams/067ef756-c710-4381-8cdd-6ba5c7b89823/apps/1601013908/testflight/crashes/APr-g7HZYfbevY4eiVzs--k` after the preceding work is validated.
Record the affected version, build, exception, crashed thread, symbolication status, and relevant user steps.
Use the actual stack and repository revision to choose the reproduction and fix.
If authentication or crash symbols are unavailable, report that precise missing evidence while continuing any independent repair work.

## Testing Details

The core gate is `rtk proxy opam exec --switch=5.5.0 -- dune build @shared/native/runtest`.
The latest complete gate passed 1024 tests in 63.858 seconds, including clipboard round trips, composer graph isolation, table edit policy, cached empty-row renderability and bounded editor retention (`/tmp/logseq-clipboard-full-core-final.log`).
Native image retention checks count actual uncached image requests and compare rendered block coordinates.
Table policy checks pass in `/tmp/logseq-table-policy-core-green.log` and native iOS geometry and interactions pass in `/tmp/logseq-table-divider-native-final.log`.
Composer graph isolation and asset recovery regressions fail before their fixes in `/tmp/logseq-composer-recovery-red.log` and all nine composer cases pass in `/tmp/logseq-composer-recovery-green.log`; three pre-existing asset capture cases also remain green.
Android initially passed 15 of 16 interaction checks, with the new vertical divider geometry case exposing an upstream missing stretch implementation. After fixing stretch and correcting an assertion for a Ready column absent from the Android fixture, all sixteen native checks pass (`/tmp/logseq-stretch-final-android-instrumentation.log`). The upstream geometry snapshot was inspected and passes `verifyPaparazziDebug` (`/tmp/logseq-lui-row-stretch-verify.log`).
Clipboard core regressions fail in `/tmp/logseq-clipboard-red.log` before implementation and pass all eleven graph-backed cases in `/tmp/logseq-clipboard-core-final.log`. Native iOS clipboard transport fails before implementation in `/tmp/logseq-clipboard-native-red-2.log`; native clipboard, exact pre-paste selection, same/different block acknowledgement, rapid typing and failure recovery pass in `/tmp/logseq-clipboard-native-input.log`. The test uses the UITextView delegate input path and the production effect drain, avoiding programmatic `insertText` bypass and parallel test-only drains.
Android clipboard transport fails before implementation in `/tmp/logseq-clipboard-android-red.log`. All eighteen native query/editor/property/outliner cases now pass in `/tmp/logseq-clipboard-android-green.log`, including actual Android clipboard creation/read, same/different block acknowledgements, rapid typing and failed storage recovery.
Direct and nested destination selection, plus a result opened through the native search field, pass `/tmp/logseq-nested-selection-final-2.log`. The check no longer injects selected snapshots manually; long-press effects return the selection projection and Copy/Unselect return the cleared projection.
Upstream LUI PR 258 now includes Android stretch at `eea10c7bf99ad1a2a40cc84b1c9657a764073d72`; both the Swift package and opam pin reference it. Local Android verification uses `/tmp/logseq-lui-override.gradle` to consume that exact upstream worktree while preserving the user's dirty `duniverse/lui` checkout.
Keyboard checks operate on the scroll view containing the measured block, rather than an arbitrary scroll view in the window.
Navigation checks assert native controller depth so a test cannot pass without a real push or pop.
Device diagnostic capture `/tmp/logseq-phone-jitter-repro.log` contains 1225 geometry/lifecycle events without note text. The keyboard dismissal at uptime 270565 follows an explicit toolbar press and is not evidence of an unexpected dismissal. Idle geometry oscillations after full snapshots and hydration are confirmed.
`outliner-hydration-stability.swift` reproduces 16pt drift before the cached-empty-row fix; `outliner-scrolling-editor.swift` independently reproduces focus loss when the active block leaves the mounted window.
The cached-empty-row native regression now passes all five refresh cycles. Persistent focused rows also pass forward/reverse scrolling without detachment or a keyboard-hide notification. Native image retention, editor geometry, and multiline keyboard handoff checks remain green. Upstream fixes are in https://github.com/logseq/lui/pull/258 (PR 257 had already merged). The diagnostic fix build was installed and launched at 01:56 on the user iPhone; the user confirmed the flicker/jitter fix at 01:57.
A diagnostic build must explicitly define `LOGSEQ_INTERACTION_DIAGNOSTICS`; Release does not define `DEBUG`. Verify `Library/Caches/interaction-debug.log` can be pulled from the phone before asking for a repro.
Clipboard tests must round-trip actual copied blocks rather than merely validating an intermediate JSON shape.
Final verification includes an iOS build, Android build/instrumentation, and a non-destructive iPhone installation.
At the user's interim installation request, the latest iOS build (build number `1792693092`) was installed and launched successfully at 02:18 on the paired iPhone, preserving the app container. It adds the tested table policy/dividers and composer graph-isolation/asset-retry fixes to the confirmed jitter fix. Installation/launch evidence is in `/tmp/logseq-table-recovery-install.json` and `/tmp/logseq-table-recovery-launch.json`. Clipboard parity, date-format settings, final native checks and the crash investigation remain open.

## Implementation Details

- Preserve the user's `apple/Package.resolved` origin hash and pre-existing `duniverse/lui` edits.
- Never reset or uninstall the user's graph data.
- Keep all code and comments in English.
- Keep master clipboard, filter, and sorting semantics authoritative.
- Avoid independent copies of editor, tag picker, and property editor UI.
- Retain standard native controls and consistent theme colors.
- Fix upstream library defects when evidence identifies the library as the owner.
- Update mobile PR 69 and upstream LUI PR 258 with the final scope and verification.
- Do not merge the current PR without a new explicit merge instruction.

## Question

No product clarification blocks the interaction fixes.
Crash investigation may require the existing App Store Connect session and matching symbols; access has not yet been checked because the user requested that investigation last.

---
