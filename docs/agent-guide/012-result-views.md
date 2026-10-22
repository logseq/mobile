# Result Views Implementation Plan

Goal: Provide native list, table, and gallery views for queries, tag objects, and property objects on iOS and Android.

Architecture: Read saved view blocks and their settings using the master graph schema, and evaluate results against the pending-operation projection.
Reuse the full outliner block renderer and action pipeline for list results.
Keep view state and failures local while sharing native LUI controls between platforms.

Tech Stack: OCaml, DataScript, LUI, SwiftUI, Jetpack Compose.

Related: Builds on `011-query-block-rendering.md`.

## Problem statement

The initial query renderer displays rich text but bypasses normal block selection, editing, children, and breadcrumbs.
Tag and property object collections also need configurable saved views.
References retain their existing presentation.

## Testing Plan

Add regression tests in `shared/test/logseq/query_block_test.ml` for full block rendering on both native host protocols, breadcrumbs, initially collapsed children, expansion, selection, editing, and select bar actions against real RPC sessions.
Include results from other pages and verify their action contexts do not add duplicate rows to the main outline.
Keep ordinary outline collapse state independent from result presentation and prevent recursive query mounting.

Add integration coverage for saved view tabs, list/table/gallery switching, case-insensitive search, master filter operators, multi-key sorting, missing values, and typed reference-backed property values.
Verify tag and property object scopes without changing references.
Exercise malformed saved views beside healthy views and verify errors remain local.
Verify table horizontal scrolling and real property edits through pending operations, including offline projection, invalid input, cancellation, and conflicts.
Run focused tests during development and `rtk proxy dune build @shared/native/runtest` for the final core gate.
Use simulator runtime checks and native platform builds without running `swift test`.
NOTE: I will write *all* tests before I add any implementation behavior.

## Tasks and execution checklist

- [x] Inspect master view storage, filter/sort behavior, native renderers, and the current selection failure.
- [x] Write the complete list interaction regression set and observe behavior failures.
- [x] Decode full result blocks in `shared/src/logseq/response_snapshot.ml` and reuse `View_outliner.outliner_row_body` through a renderer callback in `view_query.ml`.
- [x] Render breadcrumbs and child trees with result-local default folding.
- [x] Resolve result block actions through the RPC action context without polluting the page outline.
- [x] Verify list selection, select bar actions, editing, folding, and ordinary reference behavior.
- [x] Write saved view, search, filtering, sorting, scope, error, and editing integration tests before implementing those behaviors.
- [x] Add a result-view domain module using master `view-for`, `feature-type`, view type, filters, sorting, and column properties.
- [x] Integrate query, tag, and property result views into snapshots and mutation refreshes in `rpc_session.ml`.
- [x] Extend semantic property value codecs only where needed to persist master-compatible settings.
- [x] Add compact native view tabs and search/filter/sort controls, with list, horizontally scrolling table, and responsive gallery layouts.
- [x] Route editable cells through typed pending operations and present local validation or conflict errors.
- [x] Validate both platform protocols, inspect native rendering, update the demo, and record evidence.

## Behavior

| Area | Required behavior |
| --- | --- |
| Scope | Queries, tag objects, property objects; references use their existing renderer. |
| Saved views | Multiple named views stored as master-compatible blocks and selected with tabs. |
| List | Full block renderer, navigable breadcrumbs, children initially collapsed, editing and select bar actions. |
| Search | Per-view case-insensitive search combined with configured filters. |
| Filters | Master operators and typed values, including ref-backed property values and emptiness. |
| Sorting | Ordered sort keys, stable ties, missing values last. |
| Table | Horizontal scroll, readable columns, tappable editable property cells, computed cells read-only. |
| Gallery | Responsive cards with configurable visible properties. |
| Failure | Local error with recovery; siblings and application navigation remain usable. |
| Mobile UI | Accessible controls, comfortable touch targets, native keyboard and dismissal behavior. |

## Testing Details

Core regressions execute actual graph queries and session actions.
UI tests mount the real shared view and dispatch native host events, then inspect rendered blocks and selection controls.
Native runtime checks verify visible text, layout, and interaction on supported devices.

## Implementation Details

- Keep real block UUIDs throughout rendering and actions.
- Inject the full block renderer into result views to avoid a module dependency cycle.
- Keep result expansion independent of graph collapse properties.
- Load action targets from the projected graph rather than only the currently visible page.
- Preserve bounded rendering and avoid recursive nested query evaluation.
- Resolve property references before filtering, sorting, displaying, or editing cells.
- Assign new typed property values to their owner instead of mutating shared value entities.
- Store view settings using existing semantic operation infrastructure.
- Catch invalid configuration and result decoding at each view boundary.
- Preserve unrelated workspace edits.

## Question

No clarification is required to begin.
Multiple saved views follow master's tab interaction.

---

## Execution notes

The list regressions initially failed in five cases: full row rendering, breadcrumbs, folding, selection events, and cross-page actions.
Query result rows now use the same renderer and action pipeline as ordinary blocks on SwiftUI and Kotlin hosts.
Result-local folding starts collapsed and does not mutate source outline collapse state.
Cross-page actions load their source page from the projected database, while snapshots retain the original page scope.
The focused query suite passes 20 tests, the result-view suite passes 17 tests, and the complete core gate passes 941 tests.
The iOS simulator build and `QueryBlockResultsCheck` runtime check pass, including visible rich text and breadcrumbs, child folding, selection toolbar dispatch, and local errors.
Native screenshot evidence is in `/tmp/logseq-result-list-artifacts/query-block-results.png`.
Saved views, search, typed filters, multi-key sorting, table editing, gallery cards, tag collections, and property collections now run through the real core action and snapshot pipeline.
Graph settings remain EDN/DataScript values, including keywords, UUIDs, sets, maps, and vectors.
JSON is the existing native UI transport and snapshot projection, not the graph storage format.

Master conformance uses 1113 cases generated by the production ClojureScript implementation at `05c3ae73e08498e9e20f1b11c3eac5525e5e588d`.
The checked fixture includes physical reference metadata, nullable bounds, empty values, all property kinds, and all three collection scopes.
Membership is verified through the real RPC; sorting is compared using identical candidate order because Datalog result order is unspecified.
The native view algorithm is vendored at `a7191d3d9deba5e34a6fb51d6454ed1d7e680965`.
Upstream filtering and sorting fixes are in https://github.com/logseq/logseq/pull/13823.

The expanded iOS simulator runtime check passes full block rendering, folding, selection, saved tabs, horizontal table layout, cell editing, native settings presentation, gallery, search, and local errors.
Screenshots are in `/tmp/logseq-result-views-artifacts/`.
Native validation exposed an upstream LUI dynamic anchor that emitted an unsupported `stack.display=contents` combination.
Its failing regression and native-compatible box fix are in https://github.com/logseq/lui/pull/255.
The full LUI `dune runtest` gate passes.
The app now pins the corrected OCaml runtime without changing the existing Apple dependency lockfile edit.
Native iOS simulator and signed Release device builds pass.
Android arm64 native core and Debug APK builds pass.

The demo has five simple and five advanced queries, plus 36 saved List/Table/Gallery views across those queries, the Project tag, and the Score property.
The native result-view mutation pipeline submitted all 36 views to the live server and a fresh snapshot at server t=88 preserves them.
A clean import executes all 10 queries with expected row counts and renders all 36 views without configuration errors.
The signed Release app and app-owned demo files have been installed on the paired iPhone.
The existing demo directory is preserved under the app's `Documents/demo-backups/` directory.

CLI batch creation initially lost properties after canonical sync replay because insert payloads omitted subsequent property assignments.
A focused upstream regression reproduces this through actual apply-ops and canonical replay.
The fix retains final property values in inserted block payloads; full upstream native and Melange gates pass.

## Native interaction revision

User review found the first functional UI insufficiently native.
Use native view tabs on the left and separate filter, sort, and search icon actions on the right.
Remove the new-view action from the mobile UI.
Keep the entire collection aligned with the owning block bullet, including nested blocks.
Open a value selector directly from table cells, with immediate selection and explicit creation for open properties.
Use native grouped lists and toolbars for filter and sort configuration, preserving master semantics.
Fix selection toolbar ownership inside pushed block destinations.

- [x] Write interaction, value-creation, layout, and destination-selection regressions and observe failures.
- [x] Implement native tabs, toolbar icons, bullet alignment, and search expansion.
- [x] Implement direct value selection, search, clear, and open-value creation.
- [x] Replace the filter/sort settings screen with native grouped interactions.
- [x] Validate real iOS and Android rendering, then install the revised build on iPhone.


The native revision now has 22 result-view integration tests, including immediate reference selection, explicit page creation, closed-value validation, multi-value creation, filter UUID sets, toolbar ordering, expandable search, and nested bullet alignment.
The full core gate passes 947 tests.
The pushed-block selection regression reproduces the original invisible toolbar on iOS and now verifies visible Copy/Delete/Unselect actions, effect dispatch, and dismissal.
Only the visible navigation destination owns its toolbar; covered destinations and cleared selections do not retain one.
Native iOS screenshots are in `/tmp/logseq-result-views-final-artifacts/` and `/tmp/logseq-selection-artifacts/`.

Android narrow-tab truncation is verified against the actual Compose text layout: the regression fails on the fixed row and passes with Material's scrollable tab row.
LUI light and dark narrow-tab snapshots pass; the app pins `3391c4a56051a0b31eb0b2734ab50337deb5a28b`.
The full LUI Android snapshot gate has six existing baseline failures (four old screenshots and two missing identity video fixtures), reproduced on the original source with byte-identical legacy rendered images.
These existing baselines are preserved.
The mobile app's native interaction checks pass independently.

The filtering/sorting PR https://github.com/logseq/logseq/pull/13823 has been merged into dev.
Reference matching and canonical insert-property retention are submitted separately in https://github.com/logseq/logseq/pull/13825.
The CLI saved-table owner, feature, type, and sorting survive a worker restart; the canonical replay regression also passes in the full upstream gate.
Phone app updates preserve the demo and subsequent user edits, including the extra saved view.
Automatic phone launch is unavailable while the phone is locked; installation succeeds.

Final Android instrumentation passes both complete flows, including actual bullet/toolbar bounds, non-ellipsized selected tabs, reachable saved views through native swipes, a full-width search field, typed cell creation, settings, and error recovery.
Android bullet alignment uses its 24dp slot center (12dp), while the Apple native row also includes its 8pt outer inset (20pt total); both retain 22-unit nested indentation.
The final Android screenshot artifacts are in `/tmp/logseq-result-views-final-android-artifacts/`.
Four new LUI light/dark snapshots for scrollable tabs and search width verify successfully.

## Results toolbar and lazy query revision

The latest interaction replaces the query tab row with one results toolbar: disclosure/count on the left and filter, sort, search, and view-type icons on the right.
Only results and actions share this row; the query owner retains its ordinary block renderer, bullet, content, tags, editing, and selection behavior.
Tag and property collections retain saved view tabs on the left of the same action row.
Saved query views remain accessible through the type menu's Saved views submenu.
List, Table, and Gallery are type menu choices, not synthetic saved tabs.
Collections without saved views show All and default to List; changing the type persists master-compatible view settings.

Queries start collapsed without executing their simple or advanced definitions.
Opening results evaluates the current graph; closing stops query evaluation during later snapshots.
Expanded results include a 24-unit trailing gap before the next block.
Search fits the collection width, and the Apple native field uses one inline background for the icon, input, and clear control.
The app pins LUI `c1a098f2f7893b7714c3a60118413b1c6d24cd50`.

Task priority icons now open a native tap menu on both hosts, using the graph's actual closed values and stable UUIDs.
Selection, cancellation, clearing, row reuse, custom values, persistence, and sync preparation have regression coverage.

The complete core gate passes 951 tests, including the separately submitted graph-link regression.
The query suite passes 21 tests, including normal owner rendering while results are folded; the result-view suite passes 24 tests.
Android instrumentation passes five interaction flows and the URL parser unit tests pass.
Actual iOS runtime checks pass query rendering/search in light and dark themes, the priority popup and effect pipeline, and URL encoding/decoding.
Current screenshots are in `/tmp/logseq-feedback-ios-artifacts/` and `/tmp/logseq-feedback-priority-artifacts/`.

Filter and sort sheets now open at medium height and expand to large, following the calendar utility-sheet interaction.
The native backend resolves theme ancestry through extension parents, reapplies the palette to modal content, and uses the themed background for navigation lists.
The iOS regression reproduced a full-height dark sheet with system gray pixels, and checks the presented height and actual background color after the fix.
The shared settings tests verify both native hosts expose the same expandable sheet contract.
These presentation and theme checks are recorded in the project iOS simulator skill and the reusable iOS development skill.

## Live query type switching regression

The phone's saved type changed correctly, but a table containing missing property values emitted empty buttons without accessible names.
Apple rejected the entire update batch, leaving the previous List renderer visible.
Cells now expose their column and displayed value (or Empty) as their accessible name while preserving an empty visual cell.
The iOS check includes missing values and verifies that switching the current saved view actually replaces the native renderer, then switches back.
Both shared host tests also exercise type changes on a pushed query destination.

A separate bridge regression reproduced loss of earlier operations when one flush produced multiple batches.
The bridge now retains all operations in order and acknowledges their final generation, with a fast path for one batch.
The transport test covers both host profiles and verifies creation precedes the later update.
The complete core gate now passes 954 tests; the actual mobile core and native UI also switch the phone demo's saved query from List to Table to Gallery successfully.
