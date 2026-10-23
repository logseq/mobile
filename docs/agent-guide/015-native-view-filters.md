# Native View Filters Implementation Plan

Goal: Make view filters compact and give every master property/operator combination a suitable native input.

Architecture: Publish the authoritative operator list with property metadata in Result_view.
Keep master filter values and matching in Dev_view, and adapt the shared native sheet around those values.
Reuse the native calendar extension for date and datetime entry.

Tech Stack: OCaml, LUI, SwiftUI, Jetpack Compose.

Related: Builds on 012-result-views.md, 013-node-properties.md, and 014-editor-commands.md.

## Problem statement

The current sheet spends three or more rows on one condition and renders timestamp filters as raw text inputs.
The UI also offers operators that master does not support for several reference types.
A common task such as showing objects created in the last month should require selecting Created and 1 month ago.

## Testing Plan

Add RPC tests for the exact operator lists for every property type and built-in timestamps.
Add shared native UI tests that change property/operator, select relative timestamps, use calendar dates, select checkbox states, search reference values, enter numeric ranges, remove a condition, and save the master-compatible payload.
Verify that a saved relative month value stays relative on subsequent reads and matches real objects around the boundary.
Verify local errors, Cancel, All/Any mode, and multiple conditions preserve unrelated view settings.

NOTE: I will write all tests before I add any implementation behavior.

## Audit

The authority is origin/master at 05c3ae73e08498e9e20f1b11c3eac5525e5e588d.
The operator and value transition rules live in src/main/frontend/worker/handler/view.cljs.
Relative timestamp presets and calendar interaction live in src/main/frontend/components/views.cljs.
The common filter engine lives in deps/db/src/logseq/db/common/view.cljs and its mobile port shared/src/logseq/core/dev_view.ml.

| Property | Master operators | Native input |
| --- | --- | --- |
| Text, URL, node | Is, Is not, Contains, Does not contain | Searchable values for equality; text input for contains |
| Number | Is, Is not, Greater than, Less than, At least, At most, Between | Existing value choices for equality; decimal input and two bounds otherwise |
| Checkbox | Is, Is not | Checked, Unchecked, Empty; one selection |
| Date | Is, Is not, Before, After | Existing day choices for equality; native day picker for comparisons |
| Datetime | Is, Is not, Before, After | Existing values for equality; relative preset or native datetime picker for comparisons |
| Created, Updated | Before, After | Relative preset or native datetime picker |
| Page, entity, class, property and other types | Is, Is not | Searchable existing value choices and Empty |

## Implementation sequence

1. Add failing tests to shared/test/logseq/view_filter_test.ml and native UI checks.
2. Publish filterOperators and timestamp metadata from shared/src/logseq/core/result_view.ml.
3. Replace the repeated Filter N/property/operator rows in shared/src/logseq/view_query.ml with one compact property/operator/remove row and one value row.
4. Add the exact master relative presets and a Created in the last month shortcut that stores after with 1 month ago.
5. Reset incompatible values when changing property or operator using the master transition rules.
6. Reuse temporal_picker for custom dates and retain the selected date with local-time display.
7. Use a searchable selection surface for equality values and clearly distinguish Empty from no selection.
8. Run focused and complete core gates, verify both native sheets, commit independently, and reinstall the phone without resetting graph data.

## Testing Details

Tests drive the actual shared sheet, inspect its submitted effect, execute it against Graph_runtime, and query the resulting view rows.
Boundary tests use Date_time_util to calculate a calendar month rather than assuming thirty days.
Native checks validate visible compact controls and calendar interaction.

## Implementation Details

- Preserve master operator ordering and EDN value shapes.
- Keep relative timestamp strings dynamic; never replace presets with fixed numbers at save time.
- Do not expose Between for timestamps because master only offers Before and After.
- Keep touch targets at least 44 points while removing repeated section headings and redundant controls.
- Keep Cancel and Done in the existing calendar-style themed sheet.
- Keep checkbox values as booleans and reference matches as UUID sets.
- Keep empty-bound numeric ranges supported by the matching engine.
- Hide irrelevant controls as soon as the operator changes.

## Question

The scope and the example workflow are confirmed by the user.

---

## Verification

- The new filter cases first failed for absent operator metadata, missing shortcut and typed controls.
- The complete native core gate passes: 995 tests.
- Filter UI tests run against both shared native host profiles, execute submitted mutations, and verify matching rows and preserved UUID sets.
- The native iOS query-results check covers filter/sort sheet presentation, dark palette, local errors, and cancellation.
