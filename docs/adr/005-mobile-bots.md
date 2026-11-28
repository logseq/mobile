# ADR 005 · Mobile Bots and task threads

- Status · Accepted
- Date · 2026-11-28

## Context

People need to start and follow agent work from Logseq Mobile. A Bot is a
long-lived project conversation. A dispatch creates a task Session with its own
reply thread. Session histories can grow independently of the associated graph.

## Product decisions

- Put **Bots** in primary mobile navigation. Show each Bot's name and latest
  activity, with an action to create a Bot and choose its default Agent.
- Open a Bot directly into its main conversation. Put **Sessions** and pending
  decisions near the composer. A dispatch appears in the conversation with its
  Agent, status and reply count. Opening that entry shows the Session thread.
- Create a Session when a manual dispatch contains an explicit Agent selection.
  Typing `@` and choosing the dispatch action both open the Agent picker. Rank
  the Bot's default Agent first. A normal main-conversation message is stored
  with the Bot. A reply from inside a Session goes to its primary Agent. Mention
  another configured Agent in the thread to give it a turn in the same Session.
- To run a workflow, mention multiple configured Agents in the order they
  should work and send once. The Logseq worker dispatches each Agent in the same
  thread after the preceding Agent succeeds. Each turn has the original request
  and recent replies. A failed step or a request for input stops the sequence.
- Show automated Agent replies and meaningful status changes in the thread.
  Include the output or its link in the thread and show the latest activity on
  the main conversation's dispatch entry. Use a stable Bot and Session ID for
  navigation from notifications.
- Prepare an editable Automation from a scheduling request in the conversation.
  Show its time, time zone, task and Agent before saving it. An Automation can
  follow the Bot's default Agent or choose one explicitly. Each occurrence
  creates a Session and sends its summary back to the main conversation.

## Storage and execution

Use PostgreSQL as the source of truth on the local Logseq Node server. Reuse the
server's verified Logseq account identity. Scope reads, writes and client
cursors to the account. Use SQLite tables in the app for the Bot list, Session
summaries, loaded messages and a durable outbox. [Mobile architecture](../../CODEBASE_OVERVIEW.md)

| Record | Contents |
| --- | --- |
| `bots` | Owner, name, default Agent and optional graph reference |
| `sessions` | Bot, root message, primary Agent and thread status |
| `bot_thread_agents` | Upstream session identity, continuation cursor and local device per Agent in a thread |
| `messages` | Bot, optional Session, author, content and ordered ID |
| `bot_runs` | Durable execution and continuation jobs, with results and failure state |
| `bot_automations` | Bot, recurrence, time zone, task and Agent override |
| `bot_runners` | Paired device, account, enabled Agents, workspace selection and last contact |

Use a nullable Session ID for main-conversation messages. Reference the root
message from the Session so a task has one original message. Store and paginate
messages independently of Session summaries. Query the latest page by default
and load older messages by ordered ID. Use bounded incremental reads to refresh
open conversations and apply the server acknowledgement to the local outbox.

Each dispatch atomically inserts the root message, Session and first execution
job. Deduplicate resubmitted client messages with stable request IDs and
Automation occurrences with their rule ID and scheduled time. Resolve the
primary Agent when creating the Session and record the recipient of each turn.
Serialize turns within the Session. When a user brings another Agent into the
thread, provide a bounded excerpt of the preceding conversation. Each Agent
continues its own upstream session. Store the remaining workflow participants on
the active run. Atomically save a successful reply and enqueue the next
participant before the worker can claim it. If a
provider's creation result is ambiguous, surface an actionable state and
reconcile the upstream result before any retry.

The worker runs independently of the phone. Use Devin Cloud's Normal mode.
Local development uses a deterministic mock provider. Live Devin requires
an explicit server setting, a per-session ACU limit and a rolling 24-hour
limit on starts. Scheduled Devin usage is a separate opt-in.
Apply Graph writes through an authorized Logseq client, scoped to the linked
graph and block. Write outcomes and links back to the graph. Graph Sync retains
its existing encryption boundary.
[Graph sync](001-real-time-graph-sync.md)

## Local delivery

The Bots runtime owns the PostgreSQL queue, workflow order and thread replies.
The Node adapter is the self-hosted entrypoint and can also run local command
adapters. The Cloudflare Worker is the hosted entrypoint. Each deployment has
its own PostgreSQL database. Both entrypoints share the routes, Graph access
checks, queue transitions, provider adapters and device leases. Cursor and
Devin use their cloud APIs.

The Node adapter runs a background loop. The Worker uses an invocation-scoped
PostgreSQL connection, starts a short job after a dispatch when possible
and processes due work with a one-minute Cron Trigger. The hosted database
schema is applied before deployment. If a server invocation loses its lease,
a provider status poll can be repeated. An unconfirmed start is marked for
attention to avoid spawning a second upstream session.

In Desktop Logseq, **Settings → AI → Local Bot Agents** pairs a device through
its signed-in account. The user selects a workspace and opts in to Codex and
Pi. The app starts the listener in the background and restores the pairing
from encrypted local storage. A headless device can pair with
`logseq agent runner pair` and start the same listener with
`logseq agent runner listen`. The
listener uses a revocable device credential and requests assignments from
Logseq using an outbound connection. The first implementation uses bounded
polling. The existing DB worker and Agent Bridge keep serving graph access and
graph events. The Bots queue and thread replies stay in PostgreSQL.

Device capabilities include the enabled Agents and the configured repository, if
any. Local steps stay queued when an eligible device is offline. The server
grants a short, exclusive lease and the listener acknowledges start before
running the command. It renews the lease while working and submits its output
with the same lease. An unstarted lease can be reclaimed. An expired execution
requires attention because the command may already have changed the workspace.
Replies that continue a local Agent session return to the same device.
Completion and the next workflow step are recorded in one database transaction.
Paired work can be stopped by revoking the device through its account or by
unpairing on the device.

Paired devices accept work initiated by their own Logseq account in the first
version. Shared-graph members can still use providers explicitly enabled for
them by the server. Keep credentials and filesystem paths on the execution host.

Develop against the Node adapter on `feat/bot` and an isolated PostgreSQL
database. Keep server and mobile commits local. Validate account
isolation, duplicate delivery, bounded message paging, worker replies,
continuation, Automation occurrences, mobile layout and offline outbox replay.
Use a deterministic execution adapter for repeatable checks.
