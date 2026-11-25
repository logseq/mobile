# ADR 004 · Mobile comments, reactions, and notifications

- Status · Proposed
- Date · 2026-11-25

## Context

The mobile core already recognizes comment blocks and displays reaction totals. Desktop writes
comment threads and reactions into the graph. Mobile should use those same entities so both clients
can read and update the same discussions, including in encrypted graphs.
[Mobile projection](../../shared/src/logseq/core/node_presentation.ml) ·
[Desktop comments](https://github.com/logseq/logseq/blob/be07e18adddde4a9a51d480d0804e72083264d57/src/main/frontend/worker/handler/comments.cljs) ·
[Desktop reaction operations](https://github.com/logseq/logseq/blob/be07e18adddde4a9a51d480d0804e72083264d57/deps/outliner/src/logseq/outliner/op.cljs#L184-L217)

## Decision

### Comments and reactions

- Open one target at a time from its Comments action. A target can be a page or an ordinary block.
  Read existing threads linked by `:logseq.property.comments/blocks`, including range threads that
  contain the target, and recognize older comment areas attached directly to the target. Post into
  the single-target thread so a comment made on one block does not appear to address other blocks.
- Use the existing `:logseq.class/Comments` and `:logseq.class/Comment` entities, ordered like other
  outliner children. Create a thread and its first comment atomically. Preserve the draft on a
  recoverable write failure. Keep thread actions available independently of the editor selection.
- Store reactions as graph entities using `:logseq.property.reaction/target` and
  `:logseq.property.reaction/emoji-id`. A user can add or remove their own reaction to a block or
  comment. Use the authenticated graph actor in `:logseq.property/created-by-ref`. Show counts and
  selected state using the same emoji identifiers as desktop.
- Run writes through the optimistic semantic operation queue. Opening a thread makes no graph
  changes. Scope operations to the captured graph and target. Revalidate missing or deleted
  targets and reconcile concurrent changes before applying retries. Reuse existing authentication,
  encryption, and transport boundaries. [Graph sync](001-real-time-graph-sync.md)

### Notifications

- Put **Notifications** in the bottom navigation on both iOS and Android. Show an unread badge
  when another graph member comments on an owned page or block, replies in a thread the viewer
  participates in, or reacts to their block or comment. Exclude the viewer's own activity.
- Derive the inbox from the synced graph, keyed by the stable event entity UUID, and list recent
  activity newest first. A notification opens its graph and originating block or comment thread.
  A missing target leaves the inbox usable and shows that the activity is unavailable.
- Scope unread state to the signed-in account and graph. Persist read markers locally and support
  marking individual items or all visible items as read. Include a graph's notifications once its
  local mirror is available. Refresh from sync updates and retain the latest available results
  offline. Keep message text inside the encrypted graph boundary.
- Deliver opted-in system alerts through APNs on iOS and FCM on Android. Request permission from
  the Notifications screen and let users change their preference there. Register device tokens
  with the signed-in account. Revoke registrations on sign-out and remove expired tokens.
- Attach bounded routing hints to an authenticated sync transaction that creates a comment or
  reaction. Hints contain only a graph ID, stable event UUID, and intended recipient account
  IDs. The sync service can read those routing IDs, checks sender and recipient graph membership,
  and limits fan-out and request frequency. It deduplicates on event ID and queues delivery only
  after the corresponding write commits. Older writers can continue to sync; their events appear
  in the in-app inbox once the local graph receives them.
- Show generic alert text on the lock screen. Push payloads contain the graph and event IDs needed
  for navigation. Keep titles, message text, member names, and emoji inside the graph. After a
  notification tap, resolve the event against the synced graph and current account before
  navigating. Drop unavailable graph routes without changing the current account.
- Use the existing Cloudflare sync worker in the Logseq repository for registration, membership
  checks and push delivery. Keep provider credentials in worker secrets. Exercise delivery with
  staging credentials and signed mobile builds before enabling it in production.

### Platform interaction

- On iOS, use native tab selection and badge behavior, app-standard bottom sheets for threads
  and reaction selection, and VoiceOver labels that expose unread counts and selected reactions.
  Keep Search and Capture reachable on compact iPhones by adapting the tab widths.
- On Android, use Material navigation, badges, sheets, and TalkBack semantics. The system Back
  action closes the reaction picker or thread before leaving the current destination. Keep the
  reply field visible above the keyboard on both platforms and use the existing LUI components
  where they provide equivalent behavior.

## Verification

Exercise desktop-shaped fixtures, first and concurrent replies, an actor toggling only their own
reaction, graph switching and offline replay, and unread changes across relaunch. Record each
platform's thread, reaction picker, and notification navigation for the UI pull request.
