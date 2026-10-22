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
| 2 | Keyboard jitter and page flashes | Device diagnostics and native regressions reproduce and verify cached-empty-row height and offscreen editor retention fixes. Repeated native navigation now reads the core path directly; twelve push/pop cycles, nested pop-to-root, root scroll retention and guide presentation bounds pass. The user confirmed the installed idle-jitter fix. |
| 3 | Composer tags | Native controls share property selection; hashtag follows attachment/status. Nine graph-backed/shared-host checks, nine Android composer cases and the complete iOS native select/create/cancel/remove/send/recovery/graph-isolation flow pass. |
| 4 | Trim on leaving editing | Shared RPC tests cover hide, switch, selection, collapse, zoom, Return, autosave, blank content, and failed storage; full core gate passes. |
| 5 | Nested/search long press | The destination-toolbar fix from `bb4575f` passes native direct/nested/search/Recent-root/linked-from-Recent checks through the effect boundary. Actual 800ms touch holds also show the native selection bar on Journal, nested destinations, Recent root, a destination from Recent and a search result; Copy clears it. |
| 6 | Master-compatible clipboard | Thirteen graph-backed round-trip cases cover Markdown/EDN snapshots, collapsed descendants, fresh identities, typed properties/ref remapping, nonadjacent selection, empty/nonempty/parent placement, UTF-16 ranges, paragraphs, alternate list markers, fenced code/math, foreign graphs and atomic failure. The master audit additionally reproduced and fixed nested links when replacing selected text inside an existing formatted link. Native clipboard/selection/rapid-typing/failed-save checks and rebuilt packages pass on both hosts. |
| 7 | Date-format preference | Implemented the master graph property, shared 27-format lexer/formatter, all journal creation paths, live journal/reference/property/navigation labels and graph-scoped native settings menus. Twelve graph/shared-host cases and the full 1,036-test gate pass. Coverage includes storage failure, restart/sync, graph changes, all formats, invalid legacy days, UUID date commands and search-index refresh. Native iOS theme/alignment/confirmed-choice checks and all 19 Android query/editor/property/outliner/settings checks pass. |
| 8 | Table borders and editability | Thirty core cases, the complete iOS native query/view flow and all sixteen Android query/editor/property/outliner checks pass. Name/timestamps are read-only; Tags use the shared typed editor. The Android stretch root cause is fixed upstream with a verified Paparazzi geometry snapshot. |
| 9 | TestFlight crash | The mobile URL redirects to the public App Store; browser login is required and its form is open. Xcode Organizer's existing account successfully refreshed recent crash clusters and downloaded logs, but no verified mapping to the supplied feedback ID is available. The configured API key returns 404 even for this app resource, so it cannot read the requested report. Specific crash/build/root cause remain unproven pending authenticated access to that report. |
| 10 | Delivery | The interaction fixes pass the full 1,038-test core gate, native iOS checks and all 28 Android cases. Commit `04c10b4` was installed non-destructively as build `1792698528` and process `23494` was verified alive. PR 69 remains open. Delivery must be repeated after the specified TestFlight crash is resolved. |

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
The latest complete gate passes 1,038 tests in 77.285 seconds (`/tmp/logseq-interaction-audit-core-final.log`), including final clipboard link-boundary and additional structure cases, graph date preferences, composer isolation, table policy, cached empty-row renderability and bounded editor retention.
Native image retention checks count actual uncached image requests and compare rendered block coordinates.
Table policy checks pass in `/tmp/logseq-table-policy-core-green.log` and native iOS geometry and interactions pass in `/tmp/logseq-table-divider-native-final.log`.
Composer graph isolation and asset recovery regressions fail before their fixes in `/tmp/logseq-composer-recovery-red.log` and all nine composer cases pass in `/tmp/logseq-composer-recovery-green.log`; three pre-existing asset capture cases also remain green.
Android initially passed 15 of 16 interaction checks, with the new vertical divider geometry case exposing an upstream missing stretch implementation. After fixing stretch and correcting an assertion for a Ready column absent from the Android fixture, all sixteen native checks pass (`/tmp/logseq-stretch-final-android-instrumentation.log`). The upstream geometry snapshot was inspected and passes `verifyPaparazziDebug` (`/tmp/logseq-lui-row-stretch-verify.log`).
Clipboard core regressions fail in `/tmp/logseq-clipboard-red.log` before implementation and pass all eleven graph-backed cases in `/tmp/logseq-clipboard-core-final.log`. Native iOS clipboard transport fails before implementation in `/tmp/logseq-clipboard-native-red-2.log`; native clipboard, exact pre-paste selection, same/different block acknowledgement, rapid typing and failure recovery pass in `/tmp/logseq-clipboard-native-input.log`. The test uses the UITextView delegate input path and the production effect drain, avoiding programmatic `insertText` bypass and parallel test-only drains.
Android clipboard transport fails before implementation in `/tmp/logseq-clipboard-android-red.log`. All eighteen native query/editor/property/outliner cases now pass in `/tmp/logseq-clipboard-android-green.log`, including actual Android clipboard creation/read, same/different block acknowledgements, rapid typing and failed storage recovery.
Direct and nested destination selection, plus a result opened through the native search field, pass `/tmp/logseq-nested-selection-final-2.log`. The check no longer injects selected snapshots manually; long-press effects return the selection projection and Copy/Unselect return the cleared projection.
The expanded check passes `/tmp/logseq-recent-selection.log`: it pops the existing native stack, opens Recent through the actual sidebar control, selects the root, opens a linked destination and verifies selection actions there, then checks search. `apple/Tests/UI/selection-gesture.swift` is its interactive companion. Launch with `python3 apple/Tests/UI/run-simulator-runtime-check.py apple/Tests/UI/selection-gesture.swift --interactive <empty-fixture-directory>` and use actual 800ms touch holds. Computer-use checks verified the visible selection bar and Copy action on Journal, nested pages, Recent root, a destination from Recent and a search destination; the rendered nested/search screenshots were inspected.
The remaining selected-block master audit compares `compose-copied-blocks-contents`, `blocks-for-clipboard`, `paste-copied-blocks-or-text`, `selection-within-link?` and `paste-blocks` with the shared implementation. Root order, ancestor deduplication, copied descendants, snapshot identity, typed values, original reference targets and target placement agree. `/tmp/logseq-clipboard-audit-red-fixed.log` reproduces incorrect nested formatting for a partial selection inside a link. The fix checks whether the UTF-16 selection lies inside a complete formatted link, matching master's replacement rule. All thirteen cases pass `/tmp/logseq-clipboard-audit-green.log`, including a selection between two separate links that must still become a new link. An initial nonadjacent-selection fixture used an invalid fractional order; the corrected valid fixture passes without production changes.
The nested-label case additionally fails `/tmp/logseq-clipboard-nested-link-red.log`. Reusing the project's regex engine with master's non-greedy formatted-link expression fixes bracketed labels without treating text between separate links as linked. All thirteen cases pass `/tmp/logseq-clipboard-audit-final-green.log`, followed by the complete 1,038-test gate. The native clipboard transport and rapid-input/recovery check also passes `/tmp/logseq-clipboard-audit-native.log`.
Final Android rebuild succeeds in `/tmp/logseq-interaction-audit-android-final-build.log`. All 28 native query, completion/clipboard, property, outliner, date-format and composer checks pass `/tmp/logseq-interaction-audit-android-final.log` (234.085s), including actual date preference selection and tag recovery/isolation. Native iOS build and phone packaging succeed in `/tmp/logseq-interaction-audit-simulator-build.log` and `/tmp/logseq-interaction-audit-device-final-build.log`.
Upstream LUI PR 258 now includes Android stretch at `eea10c7bf99ad1a2a40cc84b1c9657a764073d72`; both the Swift package and opam pin reference it. Local Android verification uses `/tmp/logseq-lui-override.gradle` to consume that exact upstream worktree while preserving the user's dirty `duniverse/lui` checkout.
Keyboard checks operate on the scroll view containing the measured block, rather than an arbitrary scroll view in the window.
Navigation checks assert native controller depth so a test cannot pass without a real push or pop.
The repeated-navigation regression reproduces against the date-format head in `/tmp/logseq-navigation-date-head.log`; SwiftUI reports multiple updates to its navigation authority in the same frame. `LGNavigationContent` mirrored core routes into a second `@State` path. That mirror originated in `0e0d6cce`; `7634b389` later animated its synchronization. Removing only that animation still fails `/tmp/logseq-navigation-mirror-no-animation.log`, so disabling animation is not the repair. The native path now reads the core routes directly and retains only an actual native pop pending core acknowledgement. `/tmp/logseq-navigation-final.log` passes twelve real push/pop cycles, nested pushes, pop-to-root, reopening, retained root scroll identity/offset and guide presentation bounds. `/tmp/logseq-navigation-final-system.log` contains no SwiftUI navigation-authority warnings for that check's process.
The native Android composer suite passes all nine cases in `/tmp/logseq-composer-tags-android-green.log`. Its added flows exercise actual tag selection, creation, Cancel, chip removal, unchanged Unicode draft text, typed send payload, failed capture recovery, retry after removing recovered tags, graph changes and stale catalogue responses. The initial final-empty-field assertion incorrectly included the placeholder in Compose semantics; the corrected assertion checks the editable text value without changing production behavior.
The iOS counterpart passes `/tmp/logseq-composer-tags-ios.log`, using actual native multiline text input and the shared native searchable picker. It additionally verifies the composer instance survives tag editing, accepted tagged capture clears its state, and graph switches clear chips. `composer-tag-chip.png` in `/tmp/logseq-composer-tags-ios-artifacts` was visually inspected. The check locates the internal multiline text view rather than expecting SwiftUI's outer accessibility identifier on UIKit, and waits for native typing to enable Send.
The requested larger query-result toggle uses the existing shared chevron icon on both hosts instead of a tiny Unicode triangle. `/tmp/logseq-query-toggle-result-view.log` passes all 30 result-view cases and `/tmp/logseq-query-toggle-query-block.log` passes all 21 query-block cases. `/tmp/logseq-query-toggle-ios.log` passes the full native query interaction check, including fold/unfold, selection, saved views, table cells, filter/sort sheets, gallery, search and contained errors. The actual toggle screenshot was visually inspected.
The navigation repair also passes twelve native page/block search-result pushes and backs in `/tmp/logseq-navigation-search-final.log`, and direct/nested/search selection actions in `/tmp/logseq-navigation-selection-final.log`. Search checks still emit the pre-existing AttributeGraph cycle diagnostics also recorded before this repair in `/tmp/logseq-nested-selection-final-2.log`; these checks pass their behavior and geometry assertions, but those diagnostics remain an audit item.
`/tmp/logseq-navigation-editor-final.log` additionally passes native editor entry/exit across journal sections with stable block coordinates and no extra image request after the navigation change.
Device diagnostic capture `/tmp/logseq-phone-jitter-repro.log` contains 1225 geometry/lifecycle events without note text. The keyboard dismissal at uptime 270565 follows an explicit toolbar press and is not evidence of an unexpected dismissal. Idle geometry oscillations after full snapshots and hydration are confirmed.
`outliner-hydration-stability.swift` reproduces 16pt drift before the cached-empty-row fix; `outliner-scrolling-editor.swift` independently reproduces focus loss when the active block leaves the mounted window.
The cached-empty-row native regression now passes all five refresh cycles. Persistent focused rows also pass forward/reverse scrolling without detachment or a keyboard-hide notification. Native image retention, editor geometry, and multiline keyboard handoff checks remain green. Upstream fixes are in https://github.com/logseq/lui/pull/258 (PR 257 had already merged). The diagnostic fix build was installed and launched at 01:56 on the user iPhone; the user confirmed the flicker/jitter fix at 01:57.
A diagnostic build must explicitly define `LOGSEQ_INTERACTION_DIAGNOSTICS`; Release does not define `DEBUG`. Verify `Library/Caches/interaction-debug.log` can be pulled from the phone before asking for a repro.
Clipboard tests must round-trip actual copied blocks rather than merely validating an intermediate JSON shape.
Final verification includes an iOS build, Android build/instrumentation, and a non-destructive iPhone installation.
At the user's earlier interim installation request, the iOS build (build number `1792693092`) was installed and launched successfully at 02:18 on the paired iPhone, preserving the app container. It adds the tested table policy/dividers and composer graph-isolation/asset-retry fixes to the confirmed jitter fix. Installation/launch evidence is in `/tmp/logseq-table-recovery-install.json` and `/tmp/logseq-table-recovery-launch.json`. Clipboard parity, date-format settings, final native checks and the crash investigation remain open.

## Implementation Details

Date-format implementation notes from the master audit:

- Persist the graph property, not a device-only setting. Scope the mutation by graph ID and reject stale requests.
- Preserve journal UUIDs and stored titles when changing the preference; derive displayed journal titles, reference labels and date-property text from journal day. Native day-picker `editorValue` stays ISO.
- Share the 27 built-in formats already present in `Dev_query.Date_time_util`. `Dev_query` depends on `Graph_read`, so `Graph_read` cannot call back into `Dev_query`: move the pure formatter/token support into the existing pure `Journal` module and reuse it from both.
- Update creation paths in `Graph_runtime.ensure_today_journal`, `Rpc_session.ensure_journal`, `Rpc_ops`, `Pending_pump`, `Editor_command_effects` and date-property creation in `Result_view`.
- Expose the graph preference in snapshots and both native settings menus; preserve graph isolation and avoid changing active date-picker wire values.
- Date-format TDD evidence: `/tmp/logseq-journal-format-red-7.log` reproduces the missing API/menu; `/tmp/logseq-journal-format-surfaces-red.log` reproduces stale open destination titles. Ten cases pass in `/tmp/logseq-journal-format-surfaces-green.log`, and the complete gate passes 1,034 tests in `/tmp/logseq-date-format-full-core-final.log`.
- The added date-command/search cases first fail in `/tmp/logseq-date-command-search-red-fixed.log` and then pass with all twelve date cases in `/tmp/logseq-date-command-search-green.log`. Date commands now insert stable journal UUIDs. Search refresh includes journals and their referring blocks when the graph format changes; the persisted index fingerprint is versioned to rebuild older labels.
- Final date-format verification: `/tmp/logseq-date-picker-complete-core.log` passes all 1,036 core tests. `/tmp/logseq-date-settings-alignment-red.log` reproduces the double-inset/taller custom menu row; reusing the existing native picker contract passes `/tmp/logseq-date-settings-native-final.log`, including light/dark OCR alignment and spacing, colors and confirmed selection. Screenshots in `/tmp/logseq-date-settings-native-final-artifacts` were visually inspected. `/tmp/logseq-date-format-android-all.log` passes all 19 native checks (78.098s), including real dropdown selection and graph isolation.
- Existing journal read tests now assert derived calendar titles. The 10k-row check verifies physical reuse of the derived journal metadata and no stored-title decryption; the sidebar rename-cache check explicitly uses an ordinary page so it retains coverage of actual renames.

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
The requested TestFlight report still needs authenticated access. Both the in-app browser and Chrome lack a valid web session; the user has been asked to complete Apple login while independent build/install work continues. Xcode can fetch current crash clusters, including AttributeGraph failures, but the supplied feedback ID has not been correlated to a cluster. The configured API key also cannot see app `1601013908` (`GET /v1/apps/1601013908` returns 404), so its report-specific 404 must not be interpreted as evidence that the report does not exist. Do not infer this report's root cause from an uncorrelated cluster or older local logs.

---

## Latest interim device install

At the user's next "install first" request, build `1792695320` from mobile commit `89b151a` was built, signed, installed and launched at 02:56 on the paired iPhone. Process `23154` was verified alive. The install preserves the data container and includes the structured multi-block clipboard changes. Date-format work is subsequent and was not included. Evidence: `/tmp/logseq-latest-device-build.log`, `/tmp/logseq-latest-device-install.json`, `/tmp/logseq-latest-device-launch.json` and `/tmp/logseq-latest-device-processes.json`.

At 03:50, build `1792698528` (`LogseqRevision=04c10b4f`) was installed and launched on the same iPhone without uninstalling or resetting its container. Process `23494` was confirmed in the device process list. This build includes date-format settings, the direct core navigation path, larger query chevrons and final clipboard link-selection repair. Evidence: `/tmp/logseq-interaction-audit-device-final-build.log`, `/tmp/logseq-interaction-audit-device-install.json`, `/tmp/logseq-interaction-audit-device-launch.json` and `/tmp/logseq-interaction-audit-device-processes.json`. The specified TestFlight report remains an outstanding requirement; this install does not constitute completion of its crash investigation.
