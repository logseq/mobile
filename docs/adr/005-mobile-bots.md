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
  with the Bot. A reply from inside a Session continues that Session.
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
| `sessions` | Bot, root message, selected Agent, upstream session ID and status |
| `messages` | Bot, optional Session, author, content and ordered ID |
| `bot_runs` | Durable execution and continuation jobs, with results and failure state |
| `bot_automations` | Bot, recurrence, time zone, task and Agent override |

Use a nullable Session ID for main-conversation messages. Reference the root
message from the Session so a task has one original message. Store and paginate
messages independently of Session summaries. Query the latest page by default
and load older messages by ordered ID. Use bounded incremental reads to refresh
open conversations and apply the server acknowledgement to the local outbox.

Each dispatch atomically inserts the root message, Session and first execution
job. Deduplicate resubmitted client messages with stable request IDs and
Automation occurrences with their rule ID and scheduled time. Resolve the
Agent when creating the Session. Serialize continuations within that Session
and store upstream session IDs separately from Logseq Session IDs. If a
provider's creation result is ambiguous, surface an actionable state and
reconcile the upstream result before any retry.

The worker runs independently of the phone. Use Devin Cloud's Normal mode.
Local development uses a deterministic mock provider. Live Devin requires
an explicit server setting, a per-session ACU limit and a rolling 24-hour
limit on starts. Scheduled Devin usage is a separate opt-in.
Route local Agents to an explicitly configured runner and working directory.
Codex and Pi can use local command adapters. Circle can use a configured
adapter with the same input and output contract. Keep provider credentials in
server or runner configuration. An unavailable Agent leaves a visible status
and a recoverable task. Apply Graph writes through an authorized Logseq
client, scoped to the linked graph and block. Write useful outcomes and links
back to the graph. Graph Sync retains its existing encryption boundary.
[Graph sync](001-real-time-graph-sync.md)

## Local delivery

Develop against the Node adapter from the local Logseq mainline and an isolated
PostgreSQL database. Keep server and mobile commits local. Validate account
isolation, duplicate delivery, bounded message paging, worker replies,
continuation, Automation occurrences, mobile layout and offline outbox replay.
Use a deterministic execution adapter for repeatable checks.
