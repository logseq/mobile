# Shared Editor Commands Implementation Plan

Goal: Support the agreed master slash commands through the same native completion interaction as page references and tags.

Architecture: The OCaml outliner owns completion state, command discovery, and semantic mutations.
The existing completion panel renders commands, pages, tags, embeds, and templates on both native platforms.
Native date controls and shared input forms handle commands that require additional input.

Tech Stack: OCaml, DataScript, LUI, SwiftUI, Jetpack Compose.

Related: Builds on 013-node-properties.md and the existing outliner reference completion.

## Problem statement

Master supports a graph-aware slash menu, while the native editor currently only completes references and tags.
Support every built-in command except Query, Advanced Query, Query function, Add property, Add comment, Upload an asset, and Node reference.
Do not add custom or plugin commands.
Embed deletion must remove the embedding node and preserve its source and source descendants.

## Testing Plan

Add RPC integration tests in shared/test/logseq/editor_command_test.ml before implementation.
Exercise typing at UTF-16 caret positions, command filtering, every included command family, graph-defined choices, cancel and stale selection, code and escaped literals, template cloning, date and link forms, semantic synchronization, and deleting an embed.
Add shared UI integration coverage for one completion panel, search, dismissal, and choosing a command on both host profiles.
Add native UI regression flows for keyboard retention, page and tag selection, command filtering, input forms, and real calendar taps.
Run focused tests first, then the complete core gate and native platform builds.

Regression tests were added and observed failing before each implementation batch.

## Implementation sequence

1. Add and run the failing integration tests against current RPC and UI entry points.
2. Add shared/src/logseq/core/editor_command.ml and its signature for the master command catalog, graph choices, and command planning.
3. Extend shared/src/logseq/core/outliner_state.ml, outliner_effects.ml, and session_outliner.ml to share selection state and stage atomic semantic operations.
4. Extend rpc_wire.ml, rpc_encode.ml, core_effect.ml, model.ml, native_bridge.ml, and response_snapshot.ml for completion search, submission, and dismissal.
5. Update shared/src/logseq/view_outliner.ml to render one reusable completion panel with compact rows, explicit dismissal, empty states, and common picker navigation.
6. Reuse the existing native-property-date extension for date and datetime inputs and use shared forms for links and media inputs.
7. Render command output with correct headings, list numbering, code language, and linked embed content while retaining wrapper identity for deletion.
8. Run the focused integration suite, the full core gate, iOS simulator checks, Android checks, and phone build and installation without resetting graph data.

## Testing Details

Tests invoke the actual RPC session backed by Graph_runtime and inspect resulting DataScript values and pending synchronization operations.
Embed tests delete a linked wrapper and then read both the source and its child from the real projected database.
UI tests operate the same completion controls for commands, references, and tags, including cancellation without losing the draft.

## Implementation Details

- Preserve master property identifiers and semantic value types.
- Read ordered statuses and priorities from graph definitions.
- Store embeds with block/link and never replace their identity with the source UUID.
- Clone templates into new nodes with fresh UUIDs and preserve source data.
- Respect UTF-16 caret offsets, suffix text, escaped markers, code literals, and input composition.
- Keep command errors inside the editor interaction with a useful recovery path.
- Use the existing app sheet palette and native calendar controls.
- Keep the user's Package.resolved originHash change intact.

## Question

The command scope and exclusions are confirmed by the user.
YouTube timestamp insertion needs the active player position when available and an explicit timestamp input otherwise.

---

## Follow-up behavior

- Pasting a slash, page reference, or tag marker stays literal until a new trigger is typed.
- Code and math editors preserve line breaks; choosing Code in prose creates a separate code block.
- All editable pages expose a lazy trailing placeholder. Opening an empty page does not insert filler; one tap inserts and focuses a real block. Zoomed blocks insert children in their containing page.
- Empty journal pages have independent projection metadata, so an existing day remains visible with no blocks. Active apps refresh the local day after midnight or resume.
- Copied URLs include the graph ID. Graph-less block-ID links resolve in the current graph.

## Validation

- Complete native core gate: 987 tests passed in the combined working tree, including reference-display follow-ups.
- iOS simulator and signed device builds passed.
- iOS native runtime check passed for shared command/reference/tag completion, keyboard and caret retention, and real clipboard paste.
- Android app and instrumentation APKs built; both native completion and clipboard-paste checks passed.
- No graph reset or uninstall is needed for the device update.

## Follow-up parity fixes

- Backspace keeps the native UTF-16 caret at the boundary between merged titles.
- Heading levels precede Clear heading, and graph priorities precede No priority. The duplicate Normal text command is removed in mobile and upstream PR 13826.
- Native disclosure controls expose a 44-point touch target, including its edges.
- Placeholder blocks use the regular bullet asset with reduced opacity.
- The shared properties renderer uses compact task-date icons and local readable datetime labels.

## Editing geometry verification

- Reproduced the plain-text display/editor mismatch with native screenshots: one physical pixel on a single line and a 3.3-point wrapped-height difference.
- Readonly titles now use cached TextKit layout, the editor's measurement, and a pixel-aligned drawing origin. Native checks show zero ink displacement and equal title frames.
- Placeholders are hidden during editing, keep empty journal headings, and share the new empty block's bullet coordinates.
- Android grouped completion buttons retain a fixed height in their vertical scroll container. Native command, page, tag and paste checks pass.
- The full core gate passes 996 cases; the Name cell editor omits Clear value while other properties retain it.
