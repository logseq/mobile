# ADR 003: Journal task dates and quick editing

- Status: Proposed
- Date: 2026-11-23

## Context

Logseq master shows a collapsed **Scheduled and Deadline** section below today's journal content
when its query returns results. The query matches either task date, requires a status, excludes Done
and Canceled, and groups results by source page. It starts at local midnight today and defaults to a
seven-day lookahead. The journal section and lookahead are configurable per graph.
[Journal component](https://github.com/logseq/logseq/blob/ec69642b1f597841986e5998fdced24fc3404b95/src/main/frontend/components/scheduled_deadlines.cljs#L15-L45) ·
[Worker query](https://github.com/logseq/logseq/blob/ec69642b1f597841986e5998fdced24fc3404b95/src/main/frontend/worker/handler/property.cljs#L967-L994) ·
[Date bounds](https://github.com/logseq/logseq/blob/ec69642b1f597841986e5998fdced24fc3404b95/deps/common/src/logseq/common/util/date_time.cljs#L119-L127) ·
[Graph settings](https://github.com/logseq/logseq/blob/ec69642b1f597841986e5998fdced24fc3404b95/deps/common/resources/templates/config.edn#L32-L42)

Master exposes task dates in the slash menu and supports property changes from the selection action
bar. Mobile already supports `/Scheduled`, `/Deadline`, and tapping a populated date in the outline.
The editor and selection toolbars can give users a direct path to the same date editor.
[Master slash commands](https://github.com/logseq/logseq/blob/ec69642b1f597841986e5998fdced24fc3404b95/src/main/frontend/commands.cljs#L271-L286) ·
[Master selection actions](https://github.com/logseq/logseq/blob/ec69642b1f597841986e5998fdced24fc3404b95/src/main/frontend/components/selection.cljs#L97-L110) ·
[Mobile editor commands](../../shared/src/logseq/core/editor_command.ml) ·
[Mobile date editor coverage](../../shared/test/logseq/editor_command_test.ml)

## Decision

### Show tasks below today's journal

- Show **Overdue**, **Doing**, and **Planned** below today's journal blocks, before the next day in the
  Journals feed. Use the same sections on the standalone page for today's journal, including when it
  has no blocks. Omit each heading when its list is empty. The sections are expanded by default
  and can be collapsed by tapping their headings.
- Read Scheduled and Deadline across the active graph. Include dated blocks with an unset status so
  users can schedule a block and see it immediately. Exclude Done, Canceled, deleted, and recycled
  blocks. Honor `:feature/disable-scheduled-and-deadline-query?` and `:scheduled/future-days` from the
  graph configuration for the date-based sections. A configured lookahead may shorten the seven-day
  window. Use zero to show only today's dates in Planned. Doing remains available when date queries
  are disabled.
- Include dates from seven local calendar days before today through seven days after today, including
  both boundary days. The earliest date within the window determines the date bucket. A date before
  today is Overdue. A date from today through the lookahead is Planned, including timed entries
  throughout the last day. Undated Doing tasks use their last update or creation time. Label today's rows
  **Today**. A date-only value stays in Planned throughout its local day. Use calendar-day
  arithmetic across daylight saving changes.
- Show each block once. Overdue takes precedence, followed by Doing for blocks with the Doing
  status, including undated blocks. The remaining dated blocks in range appear in Planned. Sort the
  date-based sections by the earliest date and Doing by most recently updated, with the block UUID
  as a stable tie-breaker. The source page's journal date excludes blocks already in today's
  journal from all three result sections. Reuse the block renderer
  with the bullet, status control, and rich block content. Show the dates and source page on one
  line below the title, aligned with the status icon. Use the same compact date controls in the
  journal and the outline, with a calendar for Scheduled and a flag for Deadline. Apply the red
  error color to the Deadline date and flag when that deadline is before today and still open.
  Tapping either date opens its picker, tapping the source page opens that page, and tapping the
  bullet opens the original block. Tapping the title edits the original block inline, while
  long-pressing activates the usual block selection toolbar.
  [Task date icons](../../shared/src/logseq/view_property.ml)
- Keep the graph's task projection when navigating away from today. Retain the mounted rows in
  resident journal panes and remember each graph's disclosure state for the current day. Reuse
  cached results when refocusing an unchanged graph.
- Leave extra space before the task area. Use muted section titles and a right-side chevron
  that stays the same size in both states. Animate disclosures on iOS, respecting Reduce Motion.

### Update task sections from the graph

- Re-evaluate membership from the local graph, including pending edits, after date or status changes,
  sync transactions, and a change in the local journal day or time zone. Updates preserve the scroll
  position and disclosure state. Leave the journal scroll surface to handle ordinary scrolling.

### Keep the journal usable when the task query fails

- Contain query errors and exceptions at the task selector boundary. Return a recoverable error
  state to both hosts so journal browsing, editing, and capture remain usable.
- Show **Couldn't load tasks** and a **Retry** action inline below today's journal. If the current
  graph and day already have a successful result, keep those rows visible and show **Couldn't
  refresh tasks** above them. Retry runs the local query again, including offline. Coalesce
  overlapping retries and discard the results of requests for a stale graph, route, or day.
  A successful result clears the message and an empty result hides the empty sections.

### Set dates from the editor or block selection

- Put separate **Scheduled** and **Deadline** buttons in the editing toolbar on iOS and Android
  when the active block is a Task object, including instances of Task subclasses.
  Show the same two buttons in the selection toolbar when all selected blocks are Task objects.
  The calendar and flag icons open their corresponding picker directly. In a selection, a save
  applies that field to all selected Tasks. The picker has a natural-language input, a calendar,
  a separate time control, and a Clear action below them. An unset date starts at local midnight
  today. An existing date opens with its saved time.
  Keep slash commands and date chips available.
- Capture the editing block UUID or exact selected block UUIDs when opening the editor. In a batch,
  show the selection count and indicate mixed values per field. Apply only explicitly set or cleared
  fields to every captured block on Save. An untouched mixed field keeps each block's own value.
  Cancel leaves the dates intact and returns to the draft and caret or the block selection.
- Use the existing `:logseq.property/scheduled` and `:logseq.property/deadline` properties and Task
  tag behavior. Store epoch milliseconds, using local midnight for a date without a time. Setting
  a date follows the existing task-property behavior for ordinary blocks. Clearing a date preserves
  status and other task properties. Flush the latest draft through the existing editor save path
  before applying dates to the edited block.

## Implementation and verification

The OCaml core owns the selector, disclosure state, and date mutations. Read the two date attributes
from the optimistic graph and scope the projection to today's journal. Feed the results into the
existing virtualized outline using stable row keys. Swift and Kotlin forward editor events and
present the shared state. [Journal entries](../../shared/src/logseq/view_rows.ml) ·
[Pending property projection](../../shared/src/logseq/core/pending_projection.ml)

Use the guarded property-operation path and stage multi-block changes as one atomic intent. Validate
the captured targets and expected values before staging. If a target disappears or an edited date
has changed since the picker opened, keep the draft or selection and report the conflict without
applying a partial batch. Local projection and sync reconciliation use the same operation.

Verify empty journals, empty results, blocks with two dates, unset and terminal statuses, the
lookahead boundary, midnight rollover, and a daylight saving transition. On both hosts, verify
that all three sections start expanded, each date uses its own icon and accessibility label, and
fast scrolling crosses between today and older journals in both directions. Inject a query failure
on initial load and on Retry. Verify the inline message, journal editing, retention of the last
successful result for the current graph and day, and recovery via Retry.
Verify navigation to the source block, draft and caret retention, and batch set, clear, cancel,
and conflict handling. Run `dune build @shared/native/runtest` when implementing the core changes.
