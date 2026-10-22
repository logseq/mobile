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
| 8 | Table borders and editability | Thirty core cases, the complete iOS native query/view flow and all sixteen Android query/editor/property/outliner checks pass. Name is now editable with protected-name validation; timestamps remain read-only and Tags use the shared typed editor. The Android stretch root cause is fixed upstream with a verified Paparazzi geometry snapshot. |
| 9 | TestFlight crash | The exact report is now correlated through Xcode Organizer's downloaded feedback metadata to crash point `BaQJ15uF9O9nqkuDQ1AILr`, build 2.0.2 (18), revision `ce301717`. Browser login is no longer needed. The main-thread AttributeGraph/LazySubviewPrefetcher failure stack includes native navigation updates, 1.1534 seconds after launch, on iOS 27.0.1. Root cause and a causal fix remain under investigation; the available simulator runs iOS 26.0. |
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
The exact TestFlight report was subsequently found in Xcode Organizer's downloaded feedback cache without accessing credentials. Feedback `APr-g7HZYfbevY4eiVzs--k` is explicitly associated with crash point `BaQJ15uF9O9nqkuDQ1AILr`. Its binary UUID `A65B791F-2BEC-3FCE-8616-424B118A4E6C` matches the archived build 18 executable (revision `ce301717`, LUI `e91ee491`). The report describes a background crash notification; the log identifies role NonUI and a main-thread EXC_BAD_ACCESS in AttributeGraph dependency allocation, through LazySubviewPrefetcher and NavigationStackCoordinator, 1.1534 seconds after launch. The device runs iOS 27.0.1. Sanitized correlation evidence is saved in `/tmp/logseq-APr-correlation.json`. The new cold/late app/search restoration check passes on the available iOS 26.0 simulator (`/tmp/logseq-restoration-current.log`), but it has not reproduced this crash or established that the existing navigation repair fixes it. Browser login is no longer required. Do not claim a causal crash fix without further evidence.

---

## Latest interim device install

At the user's next "install first" request, build `1792695320` from mobile commit `89b151a` was built, signed, installed and launched at 02:56 on the paired iPhone. Process `23154` was verified alive. The install preserves the data container and includes the structured multi-block clipboard changes. Date-format work is subsequent and was not included. Evidence: `/tmp/logseq-latest-device-build.log`, `/tmp/logseq-latest-device-install.json`, `/tmp/logseq-latest-device-launch.json` and `/tmp/logseq-latest-device-processes.json`.

At 03:50, build `1792698528` (`LogseqRevision=04c10b4f`) was installed and launched on the same iPhone without uninstalling or resetting its container. Process `23494` was confirmed in the device process list. This build includes date-format settings, the direct core navigation path, larger query chevrons and final clipboard link-selection repair. Evidence: `/tmp/logseq-interaction-audit-device-final-build.log`, `/tmp/logseq-interaction-audit-device-install.json`, `/tmp/logseq-interaction-audit-device-launch.json` and `/tmp/logseq-interaction-audit-device-processes.json`. The specified TestFlight report remains an outstanding requirement; this install does not constitute completion of its crash investigation.


## Query disclosure and hidden date-format follow-up

The user's collapsed query screenshot exposed an unregistered iOS `app:chevron-right` name, which rendered the native missing-icon placeholder. Both query renderers now use the existing `disclosure-right`/`disclosure-down` vocabulary; iOS resolves these to the exact `arrowtriangle.right.fill`/`arrowtriangle.down.fill` symbols used by blocks. Android resolves them to the same arrows as its block disclosure. Shared tests fail before the change (`/tmp/logseq-query-disclosure-core-red.log`) and all 51 query/result-view cases pass afterward (`/tmp/logseq-query-disclosure-core-green.log`). The extended iOS check verifies both actual native icon resolutions, captures both states and passes the complete native interaction flow (`/tmp/logseq-query-disclosure-ios-green.log`). Both screenshots were inspected. All five Android query-view checks also pass (`/tmp/logseq-query-disclosure-android-green.log`).

The user subsequently requested that Date format not appear anywhere in settings. Both native settings entries and their now-unused shared UI builder are removed. Reading the graph's existing format and its underlying data behavior remain supported. Updated shared and iOS native checks first fail on the visible control (`/tmp/logseq-hide-date-format-core-red.log`, `/tmp/logseq-hide-date-format-ios-red.log`). This request supersedes the earlier date-format menu UI requirement and historical menu verification above.


## Object pages and editable table Name follow-up

The user requested that tag/property pages hide their blocks area, including the trailing placeholder. `View_rows.page_entries` now omits only the page outline/placeholder for these two page types and retains object views and references. A shared UI regression covers both native hosts, sidebar roots, linked destinations and search destinations, empty/populated pages and ordinary-page positive controls. It fails before the fix (`/tmp/logseq-object-pages-core-red.log`) and passes afterward (`/tmp/logseq-object-pages-core-green.log`); the iOS native check independently reproduces the old behavior (`/tmp/logseq-object-pages-ios-red.log`).

The user's latest table requirement supersedes the earlier read-only Name rule: Name is editable; Created/Updated timestamps remain read-only. Name uses the existing shared text editor and `Save_title` mutation, keeps its original markup/reference source in the editing field and never offers Clear value. RPC checks cover successful saving, stale-edit rejection and timestamp rejection. The initial metadata regression fails in `/tmp/logseq-name-edit-core-red.log`. Native fixture metadata and interaction checks now follow this updated contract.


## Protected page rename

The requested rename behavior is audited against master `05c3ae73e08498e9e20f1b11c3eac5525e5e588d`, specifically `deps/outliner/src/logseq/outliner/validate.cljs`, `core.cljs`, `deps/common/src/logseq/common/util.cljs` and DB property validation. A common `Node_title` policy protects built-in flags, internal identifiers and file entities, excludes journal renaming, rejects blank page names, hashtags, invalid slashes and page-to-journal conversion, and matches master duplicate scopes and case rules for ordinary pages, tags and properties. `Uunf` is pinned to its Dune Unicode 17 release to match master's NFC lookup keys rather than introducing a partial normalizer.

`Save_title` validates at the pending-operation compile boundary and updates `block/name` for pages. Table Name mutations validate through the same policy; protected rows expose a read-only Name. The page properties projection carries a separate rename capability, allowing ordinary page menus to reuse the existing property editor without exposing a Name row in the properties panel. Rename captures the owner and graph, retains failed edits for retry, closes on graph changes and uses the graph-scoped existing node-property mutation. It never offers Clear value. Existing search invalidation already refreshes a renamed entity and its referring entities; the new graph test verifies this behavior for a warmed index and checks sync compilation.

The new menu, blank-name protection and rename projection fail before implementation in `/tmp/logseq-rename-policy-core-red.log`. The graph-isolation regression independently fails in `/tmp/logseq-rename-scope-red.log`. All twelve node-property cases pass `/tmp/logseq-rename-policy-core-all.log`, including the added native-host menu and graph/search checks. An initial file-protection fixture reused the bootstrap config path and hit its unique constraint; it was corrected to a distinct file path before assessing the policy. No production behavior was changed to accommodate that fixture error.


The final name audit also found that the shared lowercase helper lacked JavaScript's context-sensitive Final_Sigma mapping. `/tmp/logseq-rename-unicode-red.log` reproduces the mismatch, and the expected Greek/apostrophe/Turkish-I cases are verified directly against JavaScript `toLowerCase().normalize("NFC")`. The shared helper now uses Unicode Cased/Case_Ignorable context in linear time. The full core gate passes all 1042 tests in `/tmp/logseq-rename-unicode-core-final.log` (66.242s).

A real RPC follow-up then exposed retained summaries and search pages staying stale even though the index had updated. `/tmp/logseq-rename-retained-red.log` fails on the already selected page's title. Snapshot summaries now resolve the current entity title, and successful title mutations refresh an existing search while retaining its loaded result limit. `/tmp/logseq-rename-retained-green.log` passes selected-page and pushed-route titles, favorites/Recent, old-query membership removal, new-query page/reference matches, stale/graph rejection and sync compilation.

Native iOS rename checks pass `/tmp/logseq-page-rename-ios.log`, covering the shared sheet, failed storage/retry, title replacement, protected-menu removal and graph-change dismissal. The editor/failure screenshots in `/tmp/logseq-page-rename-ios-artifacts` were visually inspected. An initial harness assertion incorrectly expected `runtime.lastError == nil` after an intentionally failed save; it now expects the injected storage error while checking that editing remains available. All nine Android query/object-page, hidden-date-format and actual overflow-menu rename checks pass `/tmp/logseq-page-rename-android-checks.log` (56.563s). The complete native iOS query flow also passes `/tmp/logseq-rename-query-ios-final.log`, including editable Name without Clear value and both resolved disclosure triangles.


The final retained-state fix passes the complete core gate again: `/tmp/logseq-rename-retained-core-final.log`, 1042 tests in 67.575s. The new header/menu also passes cold and late app/search restoration and lazy hydration (`/tmp/logseq-restoration-rename.log`). The final Android app and test APK rebuild succeeds (`/tmp/logseq-rename-final-android-build.log`); the nine targeted native checks above exercise the same final UI behavior. The specified TestFlight crash remains a separate unresolved requirement, with exact report correlation established but no causal crash reproduction or verified fix.


At 04:39, iPhone build `1792701491` (2.0.2, `LogseqRevision=e5c39f73`) was installed over the existing application and launched without resetting or uninstalling its data. Process `23768` was verified alive. This includes the block disclosure icons, hidden Date format controls, object-page blocks/placeholder suppression, editable table Name, protected page rename and retained title/search refresh. Evidence: `/tmp/logseq-page-rename-device-build.log`, `/tmp/logseq-page-rename-device-install.json`, `/tmp/logseq-page-rename-device-launch.json` and `/tmp/logseq-page-rename-device-processes.json`. The final rebuilt Android app/test APKs also pass all nine targeted checks (`/tmp/logseq-rename-final-android-checks.log`, 47.51s). Mobile PR 69 is updated and remains open; the TestFlight crash investigation is not marked complete.

### Isolated TestFlight crash experiments

The simulator runtime runner previously printed captured stdout before captured stderr. That ordering cannot establish whether an AttributeGraph warning happened during navigation or teardown. The runner now merges the streams, and the search regression writes monotonic phase markers to stderr before/after each push, pop and teardown. With that instrumentation, the current implementation passes twelve page/block search-result push/back cycles without cycle warnings (`/tmp/logseq-search-cycle-baseline.log`). This does not establish that earlier cycle diagnostics were harmless or that the TestFlight crash is fixed.

Two controlled source substitutions isolate the build 18 candidates while retaining the current core and the rest of the UI. Both experiments restore the exact original source bytes and rebuild the current simulator in a `finally` block; recorded original/restored SHA-256 values match.

- Exact build 18 `LGNavigationExtension.swift`: search and cold/late restoration checks pass, but the repeated-navigation check fails with native controller counts `[1, 1]`, confirming lost pushes. No AttributeGraph cycle or EXC_BAD_ACCESS is reproduced. Logs and restoration hashes: `/tmp/logseq-navigation-crash-ab-{old-search,old-restore,old-push}.log` and `/tmp/logseq-navigation-crash-ab-state.json`.
- Exact build 18 `LUIVirtualListView`, substituted into the current backend: all three checks pass with no cycle warning or crash. Logs and restoration hashes: `/tmp/logseq-virtual-prefetch-ab-{old-search,old-restore,old-push}.log` and `/tmp/logseq-virtual-prefetch-ab-state.json`. This experiment does not test the complete build 18 combination on iOS 27.0.1.

A separately signed `com.logseq.logseq.RuntimeCheck` app runs mock snapshots in its own iPhone container; it does not replace the installed Logseq app, access its graph container or use its app group. The current iOS 27.2 device run does not complete: the application changes from active to inactive after entering search, and the first native back does not finish the test. The initial run reports failure to reactivate the retained search field. Subsequent diagnostic runs remain incomplete; a SIGKILL during one debugger attempt has no corresponding retrieved RuntimeCheck crash report and is not evidence of the TestFlight SIGSEGV or of a watchdog failure. An LLDB attach observes the main thread in `mach_msg2_trap`, not the reported AttributeGraph allocation stack. Logs: `/tmp/logseq-device-runtime-check-current{,-2,-3}.log`. Foreground availability/test lifecycle must be established before interpreting these native assertions. The exact crash root cause remains unresolved.

The test container's diagnostic log confirms `UIApplicationWillResignActiveNotification` immediately after the search keyboard appears (`/tmp/logseq-device-runtime-check-interaction.log`), without establishing why it resigned. After copying this log, the independently installed RuntimeCheck app was removed (`/tmp/logseq-device-runtime-check-cleanup.json`); the regular Logseq installation/container were not modified. Both experimental source replacements are fully restored, and their final simulator rebuilds succeeded.

Final checks against the restored current simulator pass twelve search-result push/back cycles and all four cold/late app/search restoration cases, with no cycle warning: `/tmp/logseq-crash-audit-current-search.log` and `/tmp/logseq-crash-audit-current-restoration.log`. The runner also passes Python compilation and `git diff --check`. This audit changes test diagnostics/documentation only; the preceding 1042-test core gate and installed application code are unchanged.


### Visible editor ownership and native search surface

The user-device interaction log contains two different `outliner-editor` protocol nodes and two attached UITextViews for the same block. Both repeatedly become first responder, leaving the visible editor without a cursor and restoring another editor's end-of-block position. This is an ownership bug across retained panes, not a reason to force the native caret to the latest core offset.

The historical journal projection only cleared editing while `node_routes` was nonempty. `1c69e277` introduced `navigation_root_model` for retained titles, and `7634b389` applied that projection to the actual iOS root content: it erased the route/search state before the journal projection could check it. In addition, a selected journal page and the retained journal could both match the same editing UUID. Inactive cached node routes could also retain their editor state.

Decide root interaction ownership before clearing navigation state, clear interaction state in the retained journal unless it is the visible journal, and permit only the active visit in each native route stack to project editing/selection/autocomplete. Keep retained rows and scroll identities. No native caret-reset workaround is introduced.

- The new shared integration case fails before the fix with duplicate editors and passes for both iOS and Android through journals, selected journal pages and nested routes. The full gate at that stage passes 1043 tests in 66.493s.
- `outliner-editor-focus.swift` fails before the fix with two editors after selecting a journal page. Afterward it preserves one first responder and native selections at UTF-16 offsets 2, 7 and 0 across stale core acknowledgements. Evidence: `/tmp/logseq-editor-focus-{red,green}.log` and `/tmp/logseq-editor-focus-core-{red,green}.log`.
- `outliner-search-editor-focus.swift` opens an actual search result, taps its block to edit, then follows its real `open-node` row event and repeats editing. The exact build-18 implementation fails with two editors on the first search destination; the current implementation passes both destinations and all caret positions. The nested test uses a row link event, not the external host's app-navigation deep-link action. Evidence: `/tmp/logseq-search-editor-focus-{old,green}.log`.
- Four Android native completion/paste/failure-recovery checks pass against the rebuilt app: `/tmp/logseq-editor-focus-android-checks.log`.

The inline result-search fill used SwiftUI's `.quaternary` foreground hierarchy instead of an app surface token. LUI `df9b11ce` resolves the semantic surface with a system-fill fallback. Native screenshot pixel checks fail on the previous gray fill and pass for light/dark, focused/unfocused and app appearance overriding the system theme. The final pinned consumer query/view workflow also passes (`/tmp/logseq-search-surface-red.log`, `/tmp/logseq-search-surface-green.log`, `/tmp/logseq-query-search-final.log`). Upstream PR 258 is updated. Temporary cached-checkout substitutions were restored before resolving the real new pin.

### Built-in deletion and sidebar icon follow-up

Expose a core `canDelete` capability with node properties, hide Delete in protected page menus on both platforms, and reject a protected or stale confirmation at the shared model boundary. Reuse the core built-in classifier for deletion as well as title editing, including internal class/property identifiers without an explicit built-in flag and hidden system pages. Existing ordinary-page deletion remains available. Focused tests first fail on the missing capability and unprotected internal identifier, then pass with no queued operation or deleted-at mutation for protected pages (`/tmp/logseq-builtin-delete-{red,green}.log`).

Sidebar custom monochrome node icons now use the same subdued native foreground as default page icons. The shared node-icon component carries a presentation-only muted property; page titles and outliner icons retain their normal presentation.

### Full build-18 crash controls

A detached full `ce301717` consumer and its exact Swift LUI pin `e91ee491` build successfully. Its OCaml LUI source is identical to the build-18 opam pin. Unlike the earlier file substitutions, this exercises the complete old core/consumer/backend combination. It passes twelve search push/back cycles, all four cold/late restoration cases and the new native transition-hydration stress check on iOS 26. The latter submits 42 snapshots during animated push/pop transitions; this is not a claim that every intermediate snapshot was individually rendered. Logs: `/tmp/logseq-build18-full-{search,restoration,hydration}.log`. The corresponding device core/Swift library build also succeeds, but was not installed over the user's app.

Archive metadata and the original binary's build-version command confirm SDK 26.0 for build 18, matching this machine's Xcode 26.0 SDK; AppStoreTools 27B47 is not its linked SDK. Across the three retrieved crash reports, AttributeGraph's allocation fault follows an invalid free-list offset. This narrows the failure signature but does not identify who corrupted it. No exact EXC_BAD_ACCESS is reproduced, and the specific iOS 27.0.1 TestFlight crash remains unresolved.

The combined focus, deletion and sidebar changes pass the full core gate: `/tmp/logseq-focus-builtin-core-final.log`, 1045 tests in 66.323s. This includes matching iOS/Android node-icon extension fingerprints, protected delete capability/menu checks and unchanged ordinary-page deletion.

The final rebuilt iOS simulator passes all six native checks: visible editor ownership, search-result/link caret taps, protected page menu/rename failure-retry, sidebar node icons, editor/image position retention and nested/search/Recent selection actions. Logs use `/tmp/logseq-focus-final-<test-name>.log`. The sidebar screenshot was inspected: custom monochrome glyphs match the native document/control secondary gray while content titles retain their normal color.

The final Android app/test APKs rebuild successfully, and the actual protected-page overflow menu plus command/reference/tag completion and paste/failure recovery pass all five instrumentation cases: `/tmp/logseq-focus-builtin-android-final-checks.log`, 34.118s.

At 05:29, iPhone build `1792704538` (2.0.2, `LogseqRevision=63b10d4d`) was installed over the existing app and launched successfully; process `24324` was verified alive. The regular app was not uninstalled and graph data was not reset. This includes the search-destination caret fix, built-in Delete omission, subdued sidebar glyphs and semantic search surface. Evidence: `/tmp/logseq-focus-builtin-device-{build.log,install.json,launch.json,processes.json}`.


### Embed, command-form and view-control follow-up

Embedded nodes now carry an explicit presentation marker from their `block/link` source relation. Outliner rows reuse the existing node-icon renderer for the master `arrow-narrow-right` glyph, including ordered-list embeds; ordinary nodes retain their own icon/number. The existing wrapper-only deletion test remains in the gate. The new core integration first fails without the embed marker and then passes both native row profiles (`/tmp/logseq-embed-arrow-core-red.log`, `/tmp/logseq-form-embed-core-green.log`). The iOS rendered-arrow snapshot and image comparison pass in `/tmp/logseq-native-menu-final/NodeIconsCheck`.

Link/Image link forms compete with the mounted block editor when it unconditionally requests first responder on updates. The shared extension now explicitly transfers focus ownership to picker inputs while keeping the block editor mounted. Native URL and label inputs accept edits across snapshot acknowledgements, submit both values, and return focus to the retained editor on dismissal. Command/reference/tag completion continues to own the block editor. Core focus policy is covered by a failing-then-passing integration check; native iOS form, editor and search/link caret checks pass. Android completion/form/paste/failure-recovery cases also pass (five cases in `/tmp/logseq-menu-forms-android-native.log`; the separate All test in that initial combined run exposed the upstream validation omission described below).

Query result disclosure now uses a separately sized child icon: the existing filled triangle at 10 points on iOS and the platform block chevron at 24 dp on Android. The complete iOS query/view workflow passes, including both disclosure states, cell editing, filters, sort, gallery, search themes and contained errors (`/tmp/logseq-query-menu-final.log`). Its multi-appearance workflow exceeded the old 30-second runtime-check limit under concurrent compilation; the runner now accepts an optional timeout, and the successful run used 60 seconds.

The view selector opts into leading text alignment and retains native adaptive sizing and its touch region. LUI now admits this property in the shared/native schemas and honors it in SwiftUI Menu and Material TextButton labels. Its Android restrictive-property value validator needed the corresponding semantic-value case as well. Protocol RED: `/tmp/lui-menu-alignment-schema-red.log`; GREEN: 20 protocol cases and 9 schema-generator checks. The standalone Android store suite passes 10 cases, including valid start/center/end values and rejection of invalid string/numeric values (`/tmp/lui-menu-alignment-android-unit.log`). The consumer pins LUI `ebfc3273`. iOS screenshot OCR verifies All at the content leading edge while switching ordinary/tag/property pages; Android verifies the actual label edge, adaptive width and opening the selector (`/tmp/logseq-all-leading-android-final.log`, one passing case).

All six iOS native follow-up checks pass: object pages/alignment, link/image forms, the complete query workflow, actual embed glyph, visible editor focus, and search/link caret focus. Evidence is in `/tmp/logseq-native-menu-final` plus the query workflow rerun above. This follow-up does not establish a fix for the exact TestFlight AttributeGraph crash, which remains open.

The final full core gate passes 1047 tests in 77.289 seconds (`/tmp/logseq-menu-forms-core-final.log`).
