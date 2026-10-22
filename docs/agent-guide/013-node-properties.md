# Node Properties Implementation Plan

Goal: Display and edit page properties immediately and block properties when the block is opened as a node.

Architecture: Project the active node's properties from the real graph using schema metadata and stable UUID references.
Reuse the typed property editor and pending-operation pipeline already used by result tables.
Render text values below subdued labels using the existing block renderer, and render other values beside their labels.

Tech Stack: OCaml, DataScript, LUI, SwiftUI, Jetpack Compose.

Related: Builds on [012-result-views.md](012-result-views.md).

## Problem statement

Pages and zoomed blocks currently lack a complete property surface.
Ordinary outline blocks should remain compact.
The property surface must preserve native editing, cardinality, closed choices, explicit creation, conflict checks, persistence, and sync semantics.

## Testing Plan

Add real-session tests in `shared/test/logseq/node_property_test.ml` before implementation.
Exercise page and block navigation, inherited empty properties, internal metadata exclusion, text reference rendering, typed edits, stale writes, invalid choices, clearing, persistence, and sync transaction preparation.
Exercise both LUI native host profiles, including label styling, block rendering, inline values, native sheets, cancellation, errors, and snapshot refresh.
Add actual iOS and Android runtime presentation checks before implementation.
Run focused tests followed by `rtk proxy opam exec --switch=5.5.0 -- dune build @shared/native/runtest`.
Build mobile targets sequentially because each invokes Dune.
Never run `swift test`.

NOTE: I will write *all* tests before I add any implementation behavior.

## Tasks

1. Add the behavioral tests and observe failures caused by missing property projection and UI.
2. Expose reusable typed property metadata and mutation helpers from `shared/src/logseq/core/result_view.ml` without changing result-view membership checks.
3. Add `shared/src/logseq/core/node_property.ml` and its interface for bounded node-property reads and safe mutations.
4. Project properties in `shared/src/logseq/core/rpc_session.ml` for node routes and selected pages.
5. Add a dedicated node-property effect through `model.ml`, `native_bridge.ml`, and `core_effect.ml`.
6. Decode property projections in `response_snapshot.ml` and retain them in the matching model records.
7. Share the existing property-value sheet in `view_query.ml`, then mount the new `view_property.ml` surface from node and selected-page screens.
8. Verify real native layout in both appearances, typed interaction, and navigation isolation.
9. Run the full core gate, build both platforms, install on the existing iPhone without replacing graph data, and create a reviewable PR.

## Testing Details

Core tests use a persisted graph runtime rather than mocked mutations.
Native host tests send real UI events and inspect emitted core effects.
Runtime checks exercise actual SwiftUI and Compose rendering with empty and multiline values.

The complete native core gate passes 964 tests, including nine new property integration cases.
The cases cover navigation visibility, inherited empty properties, closed values, hidden metadata, typed edits, persistence, sync acknowledgements, stale edits, direct checkbox changes and rollback, multiline editing, existing-value choices, per-value text edits, and built-in page descriptions.
Actual iOS checks pass in light and dark appearances, including leading-edge alignment and a pixel check that property values and checkboxes contain no system-blue accent.
A real mobile-core check against a copied demo graph passes block property edits through `LGCoreEffectExecutor` and immediate page-property rendering.
The copied graph is isolated from the existing phone graph.
Android instrumentation covers the property surface alongside the existing five query-result checks.

## Implementation Details

- Keys use secondary label text without pills or schema identifiers.
- Keys and values use a slightly smaller 16pt font and normal weight; subdued color provides the visual hierarchy.
- Text and URL properties without closed choices occupy their own block rows below the key.
- Short non-text keys share aligned value columns; native text measurement moves long keys above their values.
- Date and datetime values use compact local-time labels and native typed pickers.
- Text property blocks omit breadcrumbs.
- Show the first three properties and reveal the rest with an Expand / Collapse control and direction icon.
- Include properties declared by tags, including inherited declarations, with cycle protection.
- Keep internal and hidden schema properties off the normal surface.
- Preserve existing table editing validation and shared-value isolation.
- Route errors to the property editor rather than the application error screen.
- Preserve the user's existing lockfile edit and phone graph data.
- Page titles have a 16pt gap before properties, the trailing gap is 12pt, and zoomed blocks add no separate leading spacer.

## Question

No blocking product questions remain.
Interpret “all properties” as user-facing assigned and tag-declared properties rather than internal database metadata.

---
