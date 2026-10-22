# Query Block Rendering Implementation Plan

Goal: Render DB graph Query blocks and their live simple or advanced query results on iOS and Android.

Architecture: Execute queries against the same pending-operation DataScript projection as the outline.
Vendor the mobile-safe query algorithms from Logseq commit `a63da5cb7993302f8c58ccf42eaf0083b77cf42b` (dev plus the fixes in [upstream PR #13821](https://github.com/logseq/logseq/pull/13821)), following the existing `Dev_sync` extraction pattern.
Serialize query results with hydrated blocks and render them through shared LUI elements so both native hosts receive the same behavior.

Tech Stack: OCaml, DataScript OCaml, melange-edn-native, LUI, native SwiftUI and Jetpack Compose hosts.

Related: Builds on `002-ocaml-platform-boundary.md` and `003-shared-domain-consolidation.md`.

## Problem statement

The mobile outline currently renders Query-tagged blocks as ordinary blocks.
It does not follow `:logseq.property/query`, execute the referenced definition, or display results.
The upstream dev branch already supplies the DSL compiler, Datalog rule and input handling, and an EDN result-transform evaluator.
The mobile app should reuse those algorithms without importing the complete desktop worker and its platform dependencies.

## Testing Plan

Add `shared/test/logseq/query_block_test.ml` with seeded real graph databases and RPC sessions.
Cover simple tag, reference, property, task and boolean queries, advanced pull and aggregate queries, dynamic context and dates, user and built-in rules, transforms, empty results, invalid definitions, hidden and recursive results, and updates after local and remote changes.
Verify Query blocks execute in snapshots and distant-row hydration, while ordinary blocks remain unchanged.
Exercise the real shared UI on both native host protocols to verify results, navigation, error and empty messages, folding, and progressive result disclosure.
Verify query-result blocks do not recursively mount their own queries.
Run focused tests during development, then `rtk proxy dune build @shared/native/runtest` as the core gate.
Use native platform build checks as appropriate; do not run `swift test`.
NOTE: I will write *all* tests before I add any implementation behavior.

## Data flow

```text
Open graph + pending operations
           |
     projected DataScript DB
           |
Query block -> referenced definition -> simple DSL / advanced Datalog
           |                                   |
           +---------------------- results + errors
                                               |
                         snapshot / content hydration
                                               |
                       shared LUI query result view
                              /              \
                           SwiftUI       Jetpack Compose
```

## Tasks and execution checklist

- [x] Inspect upstream and current outline, snapshot, hydration, and pending-projection boundaries.
- [x] Create the implementation plan and active goal.
- [x] Write all regression and integration tests and observe missing-feature failures.
- [x] Add reproducible upstream extraction in `scripts/vendor-dev-query.py` and mobile adapters in `scripts/vendor-dev-query-platform.ml`.
- [x] Generate `shared/src/logseq/core/dev_query.ml` with a matching interface and pinned source/license provenance.
- [x] Implement `shared/src/logseq/core/query_block.ml` and `.mli` for definition resolution, execution, normalization, and isolated errors.
- [x] Expose the projected database through `shared/src/logseq/core/mobile_graph.ml`, `.mli`, `mobile_session.ml`, and `session_types.ml` / `.mli`.
- [x] Integrate results with `shared/src/logseq/core/rpc_session.ml` snapshots, hydration, and query RPC reads.
- [x] Carry query payloads through `shared/src/logseq/model.ml`, `.mli`, and `response_snapshot.ml`.
- [x] Add shared result rendering in `shared/src/logseq/view_query.ml`, `.mli`, and `view_outliner.ml`, registering modules in `shared/native/dune_modules/*.sexp`.
- [x] Fix upstream query parser defects with endpoint regressions and submit a PR against dev.
- [x] Run focused and full verification, review the diff, and record results here.

Each implementation task starts by running its corresponding failing behavior test.
After implementing the minimum required behavior, rerun the focused test, then refactor and rerun it.
Checkpoint updates report progress while execution continues under the user's explicit goal authorization.

## Behavior and edge cases

| Situation | Required behavior |
| --- | --- |
| Query tag or query property | Resolve the property reference to its definition block. |
| Simple definition | Compile and execute the upstream DSL. |
| Advanced definition map | Execute `:query`, `:inputs`, and `:rules`, then optional `:result-transform`. |
| Scalar, tuple, aggregate, map results | Display readable values without inventing block identities. |
| Block results | Preserve markup and navigation identity; omit deleted, hidden, definition, and self results. |
| Query block in results | Display the block without recursively executing another query. |
| Empty definition | Display a useful empty-definition state. |
| Invalid or unsupported expression | Show a query-local error while sibling outline content remains usable. |
| Collapsed owner | Suppress query-result content. |
| Many results | Initially mount a bounded number and let the user reveal more. |
| Pending or remote edits | Recompute against the current projected DB, including hydrated distant rows. |
| Graph switch | Discard prior query data through the existing graph projection lifecycle. |

## Testing Details

Tests execute real queries over seeded DataScript databases through the session RPC and assert actual result identities and values.
UI tests mount the real shared app, apply its query-bearing snapshot, activate result controls, and inspect navigation and mounted content.
The full core test alias checks regressions in synchronization, projection, hydration, navigation, and rendering.

## Implementation Details

- Keep upstream algorithms reproducibly generated and mobile glue handwritten.
- Reuse the existing native EDN and Transit codecs.
- Adapt native platform helpers without adding browser or worker dependencies.
- Evaluate read operations against the pending projection without mutating the graph.
- Include source, kind, rows, and error state in each query payload.
- Use block JSON with markup for entity results and explicit textual cells for other values.
- Keep result navigation independent of outline editing and selection.
- Preserve bounded outline hydration and progressive result mounting.
- Surface unsupported custom Hiccup views explicitly; do not execute browser rendering code.
- Preserve pre-existing workspace edits and avoid unrelated changes.

## Question

No user input is required to begin.
Editable query builders and full desktop view customization are separate work.
Chrono-node natural-language dates remain outside upstream native support; standard relative dates and dynamic inputs are included.

---

## Execution notes

The query and host integration tests cover simple and advanced queries, tasks, priority, relative dates, pending edits, remote changes, and both native UI protocols.
Fixed two upstream tagged-reader defects in [logseq/logseq#13821](https://github.com/logseq/logseq/pull/13821): nested tag forms must be resolved recursively, and tagged constants must be flattening leaves rather than self-recursive nodes.
The vendored source now points directly to that upstream commit; no mobile parser patch or nested-reader workaround remains.
Four native endpoint regressions failed before the fix and passed afterward. The upstream worker `dune runtest` gate and focused seven-test Melange query suite pass.
The full core gate initially found two existing journal-layout checks affected by a new row wrapper.
The renderer now introduces the query wrapper only for Query blocks, preserving ordinary row structure.
The simulator visual check exposed that native buttons do not render arbitrary extension children. Query result entities now use clickable list items, which support rich-text children on both native hosts.

Validation:

- `python3 scripts/vendor-dev-query.py <upstream-checkout> --check` verifies the generated source and license against commit `a63da5cb7993302f8c58ccf42eaf0083b77cf42b`.
- The focused query suite passes all 17 tests, including both native host protocols.
- `dune build @shared/native/runtest` passes all 921 core tests.
- The iOS simulator OCaml core and SwiftUI shell compile successfully; SwiftPM uses `--disable-sandbox` and `-enable-testing`. No XCTest or `swift test` is used.
- `LOGSEQ_RUNTIME_CHECK_ARTIFACTS=/tmp/logseq-query-artifacts python3 apple/Tests/UI/run-simulator-runtime-check.py apple/Tests/UI/query-block-results.swift QueryBlockResultsCheck` passes on the booted iOS 26 simulator. It checks screenshot text recognition, rich result content, folding, navigation, progressive disclosure, empty results, and local errors.
- Visually inspected `/tmp/logseq-query-artifacts/query-block-results.png`; all three rich-text result rows are visible under their Query block.
- `git diff --check` passes. The pre-existing `apple/Package.resolved` edit is preserved.

Android execution and view behavior are covered through the Kotlin host protocol in the core suite; an Android emulator was not run.
