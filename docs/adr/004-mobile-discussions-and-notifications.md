# ADR 004 · Mobile comments, reactions, and notifications

- Status · Accepted
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

- Show reaction chips and a collapsed comment count beneath the target block. Expand comments
  inline and reply in the chosen thread. Place Add comment and Add reaction in the block selection
  toolbar and the block context menu. Page comments remain reachable from the page menu.
- Use the existing `:logseq.class/Comments` and `:logseq.class/Comment` entities. Store a
  single-block discussion as a child of its target and a multi-block discussion as a sibling
  after the last selected block. Reference all targets with `:logseq.property.comments/blocks`.
  Recognize legacy areas attached directly to a target. Create an area and its first comment
  atomically, and preserve the draft on a recoverable error.
- Store reactions as graph entities using `:logseq.property.reaction/target` and
  `:logseq.property.reaction/emoji-id`. A user can add or remove their own reaction to a block or
  comment. Use the authenticated graph actor in `:logseq.property/created-by-ref`. Show counts and
  selected state using the same emoji identifiers as desktop.
- Run writes through the optimistic semantic operation queue. Opening a thread makes no graph
  changes. Scope operations to the captured graph and target. Revalidate missing or deleted
  targets and reconcile concurrent changes before applying retries. Reuse existing authentication,
  encryption, and transport boundaries. [Graph sync](001-real-time-graph-sync.md)

### Notifications

- Put **Notifications** in the bottom navigation on both iOS and Android. Show a small unread dot in the accent color
  when another graph member comments on an owned page or block, posts to a thread the viewer
  has already commented in, or reacts to their block or comment. Exclude the viewer's own activity.
- Derive the inbox from the synced graph, keyed by the stable event entity UUID, and list recent
  activity newest first. A block comment notification opens the block and expands its inline
  discussion. Page comments open the page. The header menu contains mark-all-as-read, a persisted
  one-month filter, and the system notification preference. The filter is enabled by default.
  Disabling it shows the last year.
  A missing target leaves the inbox usable and shows that the activity is unavailable.
- Scope unread state to the signed-in account and graph. Persist read markers locally and support
  marking individual items or all visible items as read. Display the active graph’s notifications
  once its local mirror is available. Refresh from sync updates and retain the latest available results
  offline. Keep message text inside the encrypted graph boundary.
- Deliver opted-in system alerts through APNs on iOS and FCM on Android. Request permission from
  the Notifications screen or app settings. The System notifications settings contain a master
  switch and independent switches for comments and reactions. Persist each device's choices
  locally and include them in its push registration. The worker applies the device preferences
  when enqueuing notifications and again before sending. Revoke registrations on sign-out and
  remove expired tokens.
- Derive recipients in the sync worker from the structural references already visible during
  sync. The service checks the authenticated author and recipient’s graph membership, limits
  fan-out and frequency, deduplicates by graph and event UUID, and queues delivery after the
  corresponding write commits. Desktop and mobile writes follow the same path.
- Show the sender’s display name and avatar in native notifications. Use the sender’s initial
  when their public profile photo is unavailable. Show the reaction emoji, or a short comment
  preview when the graph is explicitly unencrypted. Encrypted graphs omit comment text from
  the notification payload and queue. The platform controls when notification previews appear.
- Push payloads contain the graph and event IDs needed for navigation. After a notification
  tap, resolve the event against the synced graph and current account before navigating.
  Drop unavailable graph routes without changing the current account.
- Edit a full name and photo from Account settings. Save them as Cognito profile attributes and
  upload a resized JPEG to Logseq’s existing avatar endpoint. Keep the longest edge at or below
  512 pixels and the final upload at or below 128 KiB. Sync profile metadata to the user entity
  with subsequent graph edits.
- Use the existing Cloudflare sync worker in the Logseq repository for registration, membership
  checks and push delivery. Keep provider credentials in worker secrets. Exercise delivery with
  staging credentials and signed mobile builds before enabling it in production.

### Platform interaction

- Use icon-only navigation with separate tab and Search/Capture groups on iOS and Android. Expose
  accessible tab names, selection and unread state. Adapt the groups to compact widths.
- Use each platform’s native menus for reaction choices and check the viewer’s selected reactions.
  Use the shared bottom composer and its send control for Add comment and Reply. Keep the field
  above the keyboard, disable Send for empty drafts, and restore unsent text after dismissal.
- Keep notification rows and overflow actions consistent with the rest of the app. Android Back
  returns from an opened discussion to the inbox.

## Push configuration

Local iOS device builds read the APNs environment from the selected provisioning profile. To show
sender avatars, use a host profile with Communication Notifications and provision the
`com.logseq.logseq.DiscussionNotificationService` extension. The device build can locate the
development extension profile automatically or use `LOGSEQ_IOS_NOTIFICATION_PROFILE`.

App Store and TestFlight builds use production APNs. The signing repository needs an App Store
profile for `com.logseq.logseq` with production APNs and Communication Notifications, and a
separate App Store profile for the notification service extension. Release CI checks the signed
archive and exported IPA.

Android release CI reads `LOGSEQ_ANDROID_FIREBASE_APP_ID`, `LOGSEQ_ANDROID_FIREBASE_API_KEY`,
`LOGSEQ_ANDROID_FIREBASE_SENDER_ID`, and `LOGSEQ_ANDROID_FIREBASE_PROJECT_ID` from repository
Actions variables. Use the Android app configuration for the production Firebase project and the
`com.logseq.logseq` package. Google Play builds require all four values, including AABs built for
manual upload. For test artifacts without Firebase, set `upload-play=false` and
`allow-missing-firebase=true`. Local builds accept the same names as environment variables.

Before enabling push on `logseq-sync-prod`, apply D1 migrations 0008–0010 and deploy the
discussion push Worker. Configure the Worker secrets `APNS_KEY_ID`, `APNS_TEAM_ID`,
`APNS_PRIVATE_KEY`, and `APNS_TOPIC` for production APNs with topic `com.logseq.logseq`.
Configure `FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL`, and `FCM_PRIVATE_KEY` for the Firebase project used by
Android release CI. Then set `DISCUSSION_PUSH_ENABLED=true` on the production Worker.
[Sync service change](https://github.com/logseq/logseq/pull/14103)

## Verification

Exercise desktop-shaped fixtures, first and concurrent replies, an actor toggling only their own
reaction, graph switching and offline replay, and unread changes across relaunch. Record each
platform's thread, reaction picker, and notification navigation for the UI pull request.

On signed builds using the production sync endpoint, opt in on each platform and trigger a
comment and reaction from a second account in a test graph. Verify notification delivery,
navigation to the discussion, and the per-device preferences.
