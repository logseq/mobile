# Android Repeated Enter Latency

Goal: Keep repeated Enter block creation responsive near the beginning of a page with 500 existing blocks, without changing iOS layout or adding a second editor/model.

## Validation plan

- [x] Add an opt-in emulator test that injects actual Enter key events into the installed app, records time until the next editor is focused, and verifies the original text survives repeated splits.
- [x] Run a controlled 500-block fixture before changes and identify the slow stage from real measurements.
- [x] Add focused regressions at the responsible boundary before implementing the fix, including ordering/data integrity and rapid repeated input.
- [x] Apply the smallest root-cause fix. Do not conceal latency with delays or replace native controls.
- [x] Repeat the identical fixture and measurement after changes; report median, p95, worst latency and any environment limits.
- [x] Restore the dedicated QA graph, run relevant regressions, commit separately and update the mobile review with evidence.

Only emulator-5556 and the dedicated UI Regression graph may receive fixture changes. Back up the graph using SQLite backup, restore it in finally, and reject physical device serials. No user action is required.

## Results and implementation

- Same 500-block SQLite fixture, SHA-256 `089d1ce138ae9b77332a464153f3f332c7e2f6061c04201efbe1673e60f77942`. Each round uses 3 warmups, 12 measured Enter inputs, then 20 inputs at 20ms intervals. The driver verifies every persisted split UUID, original text, empty prefix and chain order, and restores the original QA graph in `finally`.
- Baseline: median 117.5ms, nearest-rank p95 / maximum 160ms, 16 editor instances, 24/35 persisted splits. Hardware Enter after: two consecutive passing rounds, medians 91/87ms, maxima 147/126ms, one editor and 35/35 persisted splits. Native IME action after: median 66.5ms, maximum 105ms, one editor and 35/35 persisted splits.
- One run concurrent with the core gate had a 180ms outlier. Final timings run without concurrent builds/tests. These debug emulator samples measure input-to-editable Compose semantics, not complete pixel presentation or Redmi Release performance.
- Swift comparison: the pinned Apple virtual-list renderer preserves one active-editor identity. `apple/Sources/Logseq/OutlinerInlineEditor.swift` applies text/caret in the update pass, retains the first responder and buffers input during handoff. Android now preserves its lazy editor key and source scope, reconciles each handoff in one composition and queues rapid input in order through native keyboard actions/hardware keys. Shift+Enter and multi-line paste remain text.
- Profiling found repeated full-page hydration in the shared split path. Adjacent splits now update the cached page using source/new leaf and dependent labels, with normal cache invalidation/fallback for other operations. Cached results are compared with fresh reads for nested order, references, status labels, other pages and later edits.
- A separate actual-app failure exposed background journal refresh truncating rows to the initial 32. Once insertions moved the editor past that limit, its row vanished and focus jumped to the header. Refresh now retains the active page topology while editing; launch hydration remains bounded. The regression first failed, then passed across 35 insertions and an authoritative content update. This is a shared data correctness fix; no Apple renderer, app source, layout or style was changed.
- Full serialized core gate: 904 passed in 43.838s. Android JVM: 64 passed; LUI JVM: 29 passed. Installed keyboard/parity, native layout and real IME regressions are recorded in the report verification summary.
- LUI changes are pushed to main through `e3ed35af33f6c0c1965cd719327ee4dd67c47d0f`; the application pin is updated. No Dune files changed; no swift test ran.

Application code is committed and pushed as `eddb347`. The detailed report and curated evidence are published to the existing private mobile review; the source fixtures and raw artifacts stay ignored. The complete installed regression reruns pass without skips. Redmi and signed Release performance remain unverified by these emulator measurements.
