# Mobile Performance Rules

These rules apply to iOS and Android, including the shared OCaml core and native hosts. Protect the latency of everyday operations on both platforms.

## Interaction paths

- **Outliner.** Show typed text, caret changes, and block insertions promptly. Preserve focus and input order across block handoffs. Fast consecutive Enter presses in today's journal from the Journals list must insert one block per press. Exercise the same path while RTC pulls, sends, and confirms writes.
- **Properties.** Opening a property editor or changing a task status, priority, or date should respond immediately. Update the affected rows and refresh any visible list membership, sorting, or filters. Bound the work by the change and the visible results whenever possible.
- **Composer.** Opening the composer, typing, choosing tags or dates, and submitting a capture should respond immediately. Preserve drafts and show local writes without waiting for network confirmation.

## Keep interaction work small

- Give user input priority on shared executors. Keep collection queries, index maintenance, and sync work bounded so they cannot stall a burst of input. Separate local feedback from network and background work.
- Refresh widget projections after the app moves to the background or when the user acts in a widget. Keep widget snapshots off foreground edit and RTC response paths.
- Compute the notifications inbox when the user opens Notifications or follows a notification. Keep it off editor, property, composer, and background RTC paths. When the visible destination needs data from a background update, use a change-aware projection and reuse valid cached data.
- Publish control and acknowledgement state without rebuilding unrelated projections. Keep patch generation, serialization, and rendering proportional to the changed or visible rows. Preserve editor identity and avoid processing a full graph, page, or list for every keypress.

## Verification

- For changes on these paths, compare before and after with a representative large graph and RTC active. Include a burst of edits, property changes, and composer input for the affected surfaces. Check input loss and worst stalls as well as typical latency.
- Measure the normal entry point on Release device builds for affected platforms. A shared-core benchmark is useful for isolating transaction and projection work. Use native traces or timings to confirm what the user sees and distinguish input queueing, storage, sync, patch application, and layout.
- Keep a regression check for a reproduced failure. Record the graph size, device, tested interaction, and measurements in the PR. If a platform could not be tested, state which one and what remains unverified.
