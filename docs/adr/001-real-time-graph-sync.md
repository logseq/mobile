# ADR 001: Real-time Logseq graph sync

- Status: Accepted; implementation in progress
- Date: 2026-08-14
- Last updated: 2026-08-31
- Owners: Logseq and db-sync teams

## Context

At the time of this decision, Logseq read and wrote a small, Logseq-specific projection through the
Graph API and authenticates those requests with a personal access token (PAT). Its
local database also defines a reduced schema whose property types do not always
match the graph database on the server. Refreshing is periodic, so a change made by
another Logseq client is not visible immediately.

Before this work, the native persistence path was not a db-sync graph store. It serialized
OCaml values with `Marshal` into a two-column `kvs(address, payload)` table. db-sync
snapshots contain ClojureScript Transit values in Logseq's
`kvs(addr, content, addresses)` layout. Those formats must not be treated as
interchangeable. The earlier platform-to-core call and HTTP adapter also buffered one
complete JSON response. Incremental delivery now reuses db-sync's existing authorized
WebSocket and adds an entity-change pull message instead of another streaming endpoint.

Logseq needs a local, queryable copy of the selected graph and near-real-time
updates from db-sync. The design must work for both encrypted and unencrypted
graphs, preserve the server graph schema exactly, and add as little protocol and
server complexity as possible.

## Decision drivers

- Users sign in inside Logseq with their Cognito credentials; they do not open
  an external login page or create or paste a PAT.
- An authorized user can open any graph available to that account.
- The local graph uses the server-provided schema. Attribute cardinality, uniqueness,
  value type, reference semantics, and values are not coerced for the Logseq app.
- The first use of a graph creates a complete local copy before incremental sync
  begins.
- Incremental messages describe the latest affected entities, not DataScript tx-data.
- Incremental delivery is resumable, idempotent, ordered, and small.
- The server never receives graph decryption keys or plaintext for protected values.
- Logseq can create blocks and modify block properties, but cannot request an
  entity deletion.
- Authentication, networking, and operating-system integration are platform
  adapters; sync protocol, codecs, state transitions, encryption orchestration,
  persistence, and graph mutations are implemented in the OCaml core.

## Implementation state

This ADR defines the target architecture. The implementation is deliberately being
rolled out in stages, so target behavior must not be mistaken for current platform
support:

| Area | Current state |
| --- | --- |
| Apple authentication | Cognito Hosted UI authorization-code flow with PKCE through `ASWebAuthenticationSession`; refresh tokens are stored in Keychain |
| Android authentication | Cognito Hosted UI authorization-code flow with PKCE through Custom Tabs; refresh tokens are encrypted with an Android Keystore key |
| Graph discovery | Authenticated db-sync `GET /graphs`, including encrypted-graph metadata |
| Graph catalog and offline open | The complete discovered graph catalog is persisted in the app metadata store; the last selected graph and its local mirror open before authentication or network restore |
| Unencrypted iOS sync | iOS Simulator E2E against local db-sync verifies first-open snapshot import, server-to-client WebSocket sync, semantic REST creation, authoritative self-echo, online restart recovery, offline restart with a durable pending block, and cursor advancement after reconnect |
| Snapshot baseline | `snapshot/download` returns the pre-stream server `t`, schema version, row count, stream URL, and content encoding in one metadata response; OCaml commits that `t` only after atomic import |
| Sync ownership | One coordinator owns the selected graph's foreground WebSocket or bounded background replay, never both. Native code owns the socket lifecycle; OCaml owns Transit decoding, validation, cursor advancement, idempotency, and graph application. |
| Local metadata | Graph catalog, selection, pending writes, and checkpoints use versioned Transit records. Legacy `Marshal` metadata is intentionally treated as a cache miss; no old-cache migration is required. |
| Local journal reads | OCaml maintains an incremental recent-journal projection and re-queries only affected blocks, rebuilding only when journal-page membership changes. |
| iOS background sync | Background entry starts an immediate, bounded sync under a UIKit background assertion; `BGAppRefresh` is also registered for later catch-up. Each execution opens the persisted graph, submits pending semantic REST writes, and replays graph events from `appliedServerT` without graph-catalog or semantic refresh |
| Android sync transport | OCaml core, full-snapshot download/import, and the Android host's native WebSocket entity-change streaming are connected; device E2E remains pending |
| Encrypted graph sync | iOS Simulator E2E against local db-sync verifies encrypted first-open snapshot import, local key unlock and Keychain restore, semantic REST journal/block creation, authoritative WebSocket confirmation, ciphertext-only server storage, and kill/relaunch persistence |

## Decision

### 1. Authenticate inside the app with Amazon Cognito

Logseq uses Cognito Hosted UI instead of implementing password, challenge,
account-recovery, and federated sign-in screens. Apple opens the authorization
endpoint with `ASWebAuthenticationSession`; Android uses Custom Tabs. Both use the
authorization-code flow with S256 PKCE and a public app client without a secret.

Authentication is exposed to the shared application model through a small platform
service implemented independently by SwiftUI and Android. OAuth state and tokens do
not cross the OCaml graph boundary; the adapter supplies an access token only when
the OCaml core requests an authenticated transport operation.

The Cognito app client is a public native client with no client secret and allows
authorization-code and refresh-token grants. Cognito Hosted UI owns sign-in and
challenge presentation. Logseq persists tokens in Keychain or an Android
Keystore-backed encrypted store and refreshes them shortly before expiry. Every
Graph API, db-sync, asset, and key-management request will use:

```http
Authorization: Bearer <cognito-access-token>
```

The db-sync HTTP layer validates the JWT issuer, signature, expiry,
`token_use=access`, and Cognito `client_id`, then apply the same graph membership and
permission checks used by existing sync clients. A token identifies a user, not a graph. Graph
selection therefore happens only after the app calls the authenticated db-sync
`GET /graphs` operation. Semantic reads and writes remain under `/api/v1/graphs/...`;
graph discovery does not use the semantic graph-list route.

Authentication depends only on platform browser, secure-storage, cryptography, and
HTTP APIs. Amplify and the AWS SDK are not app dependencies.

PAT configuration and the PAT input screen will be removed after Cognito login is
available. PATs may remain supported by existing APIs during migration, but Logseq
Logseq will not use or persist them. Federated social sign-in is outside this decision
because Cognito User Pool federation normally uses a browser redirect; it must not
be added by silently changing the built-in-login requirement.

### 2. Use one server schema and keep sync metadata outside the graph

The db-sync server and Logseq local graph will use the exact schema encoded in
the snapshot root for the server-reported Logseq schema version. It must match the
corresponding `logseq.db.frontend.schema/schema` definition. Schema datoms and
property-definition entities already stored in the graph remain part of the
existing snapshot. Logseq will not maintain a reduced or Logseq-specific copy of
graph attributes.

The existing snapshot and tx-log formats use Transit. The new entity-change payload
will do the same so keywords, UUIDs, instants, integers, sets, and references retain
their logical types. References are normalized to stable lookup refs using the same
normalization rules as the current tx log; they are not changed into untyped JSON
strings. Cardinality-many values retain set semantics. The client will reject a
snapshot or change set when a value does not conform to the shared schema instead
of coercing it.

The Logseq cache is retained as a rebuildable UI projection,
but it is not the graph mirror and is never a sync source of truth. Each selected
graph currently has `graph.sqlite` for the Logseq-layout KVS graph and an atomically
replaced Transit `sync.checkpoint` sidecar containing graph id, schema version, and
applied server `t`. The separate app metadata store persists the discovered graph
catalog, last selected graph, pending local requests, and UI state. Those records
are not graph attributes and are not a second graph cursor.

Local graph files live under `graphs/<sanitized graph name> - <graph-id>/`.
Each graph directory contains its graph database, UI projection, checkpoint,
search index, and `Assets/` directory. Attachment metadata participates in graph
sync; attachment bytes are uploaded separately and downloaded on demand into
that graph's `Assets/`. Older ID-only graph directories are migrated before
opening their databases. Legacy shared asset paths remain readable and are
copied into the owning graph when resolved.

Metadata records are encoded as versioned Transit. Compatibility with the earlier
`Marshal` cache is intentionally out of scope: an old record is a cache miss and is
rebuilt from the selected graph or server. This does not change the graph SQLite
layout, server schema, or the type of any graph property.

No local-only attributes such as sync status or cached JSON projections will be
added to the graph database. This prevents the Logseq app from changing the meaning
or type of any server property.

Schema changes are a synchronization boundary. A WebSocket `reset` message with reason
`schema-changed` makes the client download a new snapshot into a new local database
and atomically replace the old database after validation. The client must not try to
infer or migrate a newer server schema.

### 3. Implement the client sync engine in OCaml

All cross-platform sync behavior will be implemented once in the existing native
OCaml core. Swift and Kotlin must not contain independent implementations of the
snapshot importer, WebSocket event decoder, cursor state machine, entity merge rules, schema
validation, E2EE value transformation, optimistic reconciliation, or write
allowlist.

The OCaml core owns:

- the db-sync request and response types;
- Transit and EDN codecs;
- WebSocket event validation, replay, and server `t` state;
- framed snapshot decoding, staging, schema-first import, and atomic activation;
- the exact Logseq graph schema and typed DataScript values;
- entity upsert and remote-deletion application;
- E2EE key-state and protected-value transformation, using platform crypto
  primitives where required;
- validation that outgoing mutations are block creation or block-property updates;
- local query projections consumed by the Logseq UI.

Platform code is limited to Cognito UI and SDK calls, HTTP/WebSocket transport,
secure key and token storage, file handles, OS cryptographic primitives, background
lifecycle, and presentation. These adapters pass opaque byte chunks and explicit
results to OCaml. They do not parse or rewrite graph values.

The WebSocket adapter opens and owns the platform network task, then feeds complete,
bounded messages and terminal results into short, serialized OCaml FFI calls. It must not hold
an OCaml runtime lock for the lifetime of a connection. Blocking native REST
transport releases the OCaml runtime while waiting, so an unreachable server cannot
serialize unrelated local graph operations behind its timeout. Snapshot downloads
likewise stream to a file or bounded OCaml decoder;
they are not materialized as one JSON RPC string.

The existing JSON RPC across the Swift/Kotlin-to-OCaml FFI remains a small control
and UI envelope. Graph snapshots, WebSocket entity values, and outgoing graph mutations
do not pass through `Yojson.Basic`; keeping them as typed OCaml values avoids the
property-type loss this ADR forbids.

Both codec projects are cross-target OCaml implementations supporting native OCaml,
js_of_ocaml, and Melange; they are not Melange-only libraries. Logseq's mobile
core uses their native backends:

- `melange-transit-native` for the existing db-sync Transit JSON protocol, snapshot
  row contents, entity events, keywords, UUIDs, dates, maps, sets, and tagged values;
- `melange-edn-native` for schema or configuration artifacts that are represented as
  EDN and for typed EDN/Yojson conversion at explicit non-graph boundaries.

The shared core packages provide the common value models, and the native packages
provide native parsing and writing. The js_of_ocaml and Melange variants are not
runtime dependencies of the mobile app, but their cross-backend test suites are
useful compatibility evidence for payloads also produced by ClojureScript.

Transit remains the sync wire format. EDN is not an intermediate representation for
Transit payloads. The dependencies are pinned to exact Git revisions by the native
dependency build script so Apple and Android builds use the same codec version. Cross-codec
fixtures copied from `logseq-1` must prove byte-level decoding compatibility before
the old JSON projection path is removed.

`datascript-ocaml` already uses `melange-transit-native` in its native SQLite work
and contains `Logseq_sqlite_storage`, which recognizes Logseq's Transit root, tail,
and persistent-sorted-set nodes and has tests against generated and real Logseq
graphs. That implementation will be promoted from its example library into a
supported package and reused. The existing `datascript-ocaml-native.sqlite` adapter
and Logseq's `Marshal` codec cannot open a db-sync snapshot directly and will
not be used to decode it.

### 4. Bootstrap with the existing db-sync snapshot download

When a user opens a graph that has no completed local copy for its graph id and
schema version, the client will follow the existing db-sync snapshot contract used
by Logseq:

1. `GET /sync/:graph-id/snapshot/download` to obtain the existing snapshot stream
   URL together with the current server transaction number `t`, schema version,
   row count, and content encoding. That `t` is the pre-stream replay baseline.
2. Download the gzip-capable framed Transit stream of SQLite `kvs` rows
   `[addr, content, addresses]`.
3. Stage those rows unchanged in a temporary Logseq-layout SQLite database.
4. Use the promoted native `Logseq_sqlite_storage` Transit decoder to load the
   snapshot schema and datoms, then reconstruct the app's local DataScript graph in
   schema-first import order, as the current `frontend.worker.sync.download`
   implementation does.

The platform adapter may inspect the stream URL and content encoding to perform the
download, but passes the original metadata response to OCaml. The OCaml sync session
validates `t`, schema version, and row count and owns the import checkpoint.

No new snapshot envelope or parallel Graph API snapshot route will be introduced.
The existing snapshot preserves all `kvs` graph storage; both server and client open
it with the same version of `db-schema/schema`. Asset bytes remain in the existing
asset API; asset entities and metadata are in the graph snapshot.

The snapshot-download handler reads baseline `t` before the client consumes the
separate snapshot stream. After import, WebSocket replay starts from that `t`, so every
transaction concurrent with snapshot streaming is considered again.
Complete entity upserts are idempotent, making an entity already present in the
snapshot safe to replay. db-sync must not garbage-collect tx-log entries newer than
the baseline while the download is active; if it cannot serve the range, it sends a
reset and the client downloads again.

The client verifies the stream framing and imports into a new local database. It
records the baseline `t` only after import succeeds, then exposes the graph. An
interrupted or invalid import is discarded and restarted; a partial graph is never
opened.

### 5. Support encrypted and unencrypted graphs with the same sync protocol

The existing graph-list metadata identifies whether a graph is encrypted. For an
encrypted graph, Logseq will use the existing Logseq E2EE key flow:

1. Fetch the user's encrypted private key with the Cognito access token.
2. Unlock it locally with the user's E2EE password.
3. Fetch the graph AES key encrypted for that user.
4. Decrypt protected attribute values and encrypted assets only on the device.

The server stores and transmits protected values as ciphertext and does not receive
the password, private key, or plaintext AES key. Unprotected schema and identity
fields remain available to db-sync so it can authorize access, identify affected
entities, and produce change sets.

The existing snapshot format and the new entity-change format each work for both
encrypted and unencrypted graphs. For encrypted graphs, the local DataScript graph
is an exact ciphertext mirror of the server graph. Protected datoms are not replaced
with plaintext during snapshot import or WebSocket event application. Local queries build a
separate decrypted UI projection on demand. This avoids a second persisted graph
shape and ensures restart, replay, and export preserve the same values the server
stores. Existing Logseq encryption metadata, Transit value envelopes, and algorithms
are reused rather than introducing a Logseq-specific format. Non-protected values keep
their original DataScript types; encrypted values keep the server's existing E2EE
representation unchanged in the mirror.

If the key is missing, access was revoked, or decryption fails, the app stops import
or event application and locks the graph. It does not store a partly decrypted graph
or fall back to treating ciphertext as user content.

### 6. Stream entity change sets over the existing WebSocket

db-sync exposes one authorized WebSocket for the selected graph:

```http
GET /sync/:graph-id
Upgrade: websocket
Authorization: Bearer <cognito-access-token>
```

After connecting, Logseq requests entity changes from its last committed cursor:

```json
{"type":"entity/pull","since":48192}
```

The server already broadcasts `changed` messages containing the latest server `t`.
The client coalesces those notifications and sends another `entity/pull` only when no
pull is in flight. On token expiry or disconnection, it obtains a current token and
reconnects with bounded exponential backoff from its durable cursor.

Normal responses use the existing monotonically increasing, graph-branch-scoped
server transaction number as the cursor:

```json
{"type":"graph-changes","data":"<Transit payload>"}
```

The actual `data` payload is Transit-encoded even when shown as JSON above. It has
only these change collections:

- `upserts`: the complete latest server representation of each affected entity;
- `deleted`: stable remote entity identifiers for entities that no longer exist.

An entity identifier is a typed lookup identity, not a numeric DataScript entity
id. The initial protocol supports `[:block/uuid <uuid>]` and `:db/ident` identities,
which are exactly the identities retained by the current normalized tx log. An
upsert is encoded as that identity plus a complete attribute map. Every reference
value is encoded as a typed lookup identity as well; no server-local numeric entity
id crosses the wire.

The implementation reuses `storage/fetch-tx-since`, `storage/get-t`, and the current
DataScript connection in the per-graph Durable Object. For `t-before`, the handler
captures the current immutable database value and `t-now`, reads normalized tx-log
entries in `(t-before, t-now]`, and extracts stable entity identities from their
entity positions, `:block/uuid` additions, and `:db/retractEntity` lookup refs. It
deduplicates those identities and reads their current datoms from the captured
database, converting reference entity ids back to lookup identities according to
the exact schema.
Each surviving identity becomes one latest-state upsert; each affected identity
absent from that database becomes a deletion. The event advances directly to
`t-now` because the protocol promises the latest state, not every intermediate
transaction.

The current normalizer does not retain a stable identity for every possible
DataScript entity (for example, a file entity identified only by `:file/path`). The
server must not emit a partial entity or numeric id in that case. Before enabling
WebSocket entity replay for such entities, normalization is extended to retain every supported unique
identity and the server capability's minimum cursor is advanced. A replay that
encounters an older unidentifiable transaction returns `reset` and requires a fresh
snapshot. This keeps legacy tx-log limitations explicit instead of silently losing
changes.

For a live commit, the transaction listener can perform the same derivation from
the transaction report's tx-data and immutable `db-after`, paired with the existing
server transaction number. Capturing the database value and `t-now` under the
graph's serialized writer prevents a transaction from being present in one and
absent from the other.

Raw datoms and tx-data remain an internal change index and are never sent to Logseq
Logseq. Multiple writes to an entity in the range produce one final upsert. If an
entity was changed and then deleted, only its id is included in `deleted`. No
unchanged entity is included. Transactions that affect no graph entity can advance
`t` with an empty change set so continuity is preserved.

An upsert is a complete entity, rather than a partial property patch. This is the
smallest idempotent unit that also communicates property retractions without
recreating tx-data semantics. Applying the same event more than once has no effect:
the client replaces the known attributes of every upserted entity, retracts local
attributes absent from that representation, and retracts every deleted entity.

The client applies one event and advances its local `t` in one durable operation.
It must reject an event when its graph id or schema version differs, or when
`t-before` does not equal the last committed `t`.

If the requested cursor has expired or is ahead of a reset server, the schema changed,
a message is too large, or the server cannot prove a contiguous range, the server sends:

```json
{"type":"reset","data":"<Transit reset payload>"}
```

Reset-style snapshot replacement closes existing sockets so they reconnect against
the new graph generation. The client then closes the socket and repeats the full-snapshot process. Reconnect
replay is at least once; the cursor and idempotent entity upserts make duplicates safe.

### 7. Restrict client writes to block creation and property modification

Logseq may submit only these mutations through authenticated server APIs:

- add a new block;
- modify properties of an existing block.

Writes use the existing semantic REST resources under `/api/v1/graphs/:graph-id`.
Block creation uses `capture` (and the corresponding task or asset operation), and
property changes use the block property update resource. Logseq does not call
the db-sync tx-batch endpoint and does not submit raw DataScript transactions.

The client will not expose or call entity-delete, page-delete, block-delete,
retract-entity, arbitrary transaction, move, or asset-delete operations. The server
must enforce this allowlist; hiding controls in the UI is not sufficient. For an
encrypted graph, the client encrypts protected property values with the graph AES
key before upload, using the existing E2EE codec.

If a journal page for a pending encrypted create does not yet exist, the client first
calls the existing semantic page-create resource. It supplies Logseq's deterministic
journal UUID, encrypted `:block/title` and `:block/name` values, and the integer
`:block/journal-day`. The server creates only that explicitly described journal page,
keeps the existing attribute types, and treats a retry with the same identity as
idempotent. The pending block is then sent through capture, task, or asset REST using
that page UUID. This avoids both raw tx submission and server-side plaintext
generation.

This restriction applies to mutations initiated by Logseq. The local database
is still a mirror, so it must apply deletions received over WebSocket sync when another
authorized Logseq client or server process deletes an entity. A remote deletion is
never converted into or replayed as a client-originated delete request.

A successful create or property update is not considered synchronized merely
because its HTTP request succeeded. The originating client receives the same
authoritative entity upsert through WebSocket sync as other clients. Optimistic UI state may be
shown separately, but only the authoritative sync event advances the graph cursor and replaces the
local graph value. Existing server conflict and permission rules remain
authoritative.

Every supported mutation is local-first. The OCaml core commits it to the app's
durable pending store before the UI publishes the result. A single serialized sync
pump sends queued operations when transport is available. An HTTP failure
leaves the operation retryable; it must not roll back the local edit, hide the graph,
or block subsequent create, edit, search, and navigation operations. A remote read
or refresh cannot overwrite an unsynchronized local value. On successful REST
submission the operation enters a submitted state and remains overlaid on the graph
mirror until the matching WebSocket upsert confirms the authoritative value.

### 8. Use cursor replay during iOS background execution

iOS does not guarantee a continuously running network connection after the app is
backgrounded. The app therefore keeps the long-lived WebSocket task for foreground use,
starts an immediate bounded sync under a UIKit background assertion when the scene
enters the background, and registers a `BGAppRefresh` task as an opportunistic later
catch-up mechanism. The refresh task is registered and initially scheduled during app
launch, then rescheduled whenever the scene enters the background and whenever a
background execution begins.

During each execution window the app:

1. opens the app metadata database and the last selected graph's local SQLite mirror;
2. obtains a current Cognito access token, refreshing it through the OAuth token
   endpoint when necessary;
3. restores the persisted graph catalog, selection, schema, and `appliedServerT`
   checkpoint without refreshing the graph catalog or downloading a new snapshot;
4. submits durable pending writes through the semantic REST allowlist;
5. opens the graph WebSocket and sends `entity/pull` from `appliedServerT`, consumes
   the first complete response, applies the available latest entity changes, commits
   the new cursor atomically, and closes the socket rather than holding background execution open.

The background path never calls the semantic recent-block refresh API. If the graph
has no valid local baseline, the task exits and leaves first-open snapshot download to
foreground execution. If an encrypted graph cannot restore its cached key, the task
leaves its pending operations intact and exits without applying ciphertext as user
content. `BGAppRefresh` timing remains controlled by iOS; strict push-time background
delivery would require a later APNs silent-push capability and is not part of this ADR.

## End-to-end flow

1. Log in through Cognito Hosted UI using authorization code with S256 PKCE.
2. List authorized graphs and select one.
3. Resolve the graph's schema version and encryption flag.
4. If encrypted, unlock the graph key locally.
5. If no valid local copy exists, call the existing `snapshot/download` API, retain
   its metadata `t` as the pre-stream baseline, and atomically import its framed
   `kvs` row stream.
6. Open the graph WebSocket and request changes from baseline server transaction number `t`.
7. Apply ordered entity upserts and deletions transactionally and persist each
   cursor.
8. On disconnect, refresh the Cognito session if necessary and resume from the
   committed cursor.
9. On `reset`, build a new local database from a fresh full snapshot.
10. When iOS grants background time, reopen the last graph, submit pending writes,
    and run one cursor-based event replay without semantic polling.

## Required server changes

- Reuse the existing Cognito JWT verification and graph access checks, and add the
  Logseq Cognito app client id to the allowed client ids.
- Expose graph encryption and schema-version metadata in the graph list.
- Keep `GET /sync/:graph-id/snapshot/download` and its framed Transit `kvs` stream as
  the only full-download path. Its metadata response includes the pre-stream `t`,
  schema version, row count, stream URL, and content encoding; bootstrap does not
  add a separate `/pull` request.
- Extend the existing `/sync/:graph-id` WebSocket with `entity/pull`,
  `graph-changes`, and `reset` messages; do not add a parallel event endpoint.
- Use `storage/fetch-tx-since` and `storage/get-t` to find affected stable entity
  identities, then pull their latest values from the current DataScript connection;
  do not introduce a second change database, cursor, or an `as-of` query.
- Use the Cognito `client_id` claim to enforce that Logseq may call only
  block-create and block-property-update mutations.
- Allow encrypted semantic writes only for the explicit Logseq operations. Encrypted
  journal creation requires a deterministic UUID, encrypted title and name, and the
  existing integer journal-day attribute; it does not accept arbitrary tx-data.
- Emit metrics for connected streams, replay lag, event size, reset reason,
  authorization failure, and snapshot duration.

## Required Logseq changes

- Replace PAT configuration with Cognito Hosted UI login, OAuth refresh and logout,
  and platform secure storage.
- Add pinned `melange-transit-native` and `melange-edn-native` dependencies to the
  OCaml build.
- Promote and reuse `datascript-ocaml`'s tested Logseq KVS Transit reader; do not
  feed server snapshot rows to the historical `Marshal`-based SQLite adapter.
- Implement protocol codecs, snapshot import, WebSocket sync state, entity application, E2EE
  orchestration, and mutation validation as OCaml modules behind narrow signatures.
- Keep Swift and Kotlin adapters byte-oriented and free of graph-schema or sync-state
  logic.
- Add graph selection and encrypted-graph unlock states.
- Replace the reduced local schema with the exact `logseq-1` graph schema for the
  server-reported schema version and reuse the current snapshot row import design.
- Store the applied server `t` and snapshot import state outside the graph database.
- Persist the full graph discovery catalog and last selected graph in the app
  metadata store so an existing graph opens without authentication or network.
- Use the platform WebSocket client with reconnect, replay, atomic event application, and reset
  handling.
- Add byte-stream platform adapters and short serialized FFI entry points so the
  current blocking JSON RPC mutex is never held by a live stream.
- Query the local full graph for Logseq views and expose only add-block and
  modify-block-properties mutations.
- Persist every mutation before presentation, send queued writes only through the
  semantic REST API, and retain optimistic values until authoritative WebSocket echo.
- Reuse Logseq's E2EE key and value codecs, persist the exact ciphertext mirror, and
  expose plaintext only through an in-memory decrypted query/UI projection.
- Register and schedule iOS background refresh, restore the last selected local
  graph, submit pending writes, and replay graph events from the durable cursor
  without calling semantic refresh.

## Consequences

### Positive

- The Logseq app sees changes shortly after they commit without periodic full refresh.
- Full local data enables offline and low-latency queries.
- Reusing db-sync snapshot download and the DataScript tx-data log avoids a second
  snapshot or change-history subsystem.
- One schema and typed transport prevent subtle cross-client property corruption.
- Entity snapshots are simpler and safer to apply than raw transaction history.
- Reusing db-sync's existing authenticated WebSocket avoids a second long-lived
  transport and its duplicate connection management.
- The same protocol supports encrypted graphs without weakening E2EE.
- One OCaml sync engine gives Apple and Android identical cursor, codec, schema,
  encryption, and mutation behavior.

### Negative

- A first open can be expensive for a large graph.
- Complete affected entities may repeat unchanged attributes, although only affected
  entities are sent.
- The server must retain enough cursor history for useful reconnects or force a new
  snapshot.
- Mobile lifecycle limits mean real-time delivery is guaranteed only while the app
  can maintain the stream; cursor-based `BGAppRefresh` remains a best-effort fallback
  whose timing is controlled by iOS.
- E2EE password and key recovery add user-visible failure states.
- Built-in Cognito authentication requires native UI for all enabled challenge
  states on both Apple and Android platforms.
- The native OCaml build gains two codec dependencies and requires compatibility
  fixtures against the ClojureScript server formats.

## Rejected alternatives

### Continue polling the Graph API

Polling is simple but wastes requests, increases update latency, and cannot provide
a reliable contiguous cursor.

### Embed Cognito SDK authentication screens

Embedding separate native authentication screens duplicates Cognito challenge and
recovery behavior and adds a large SDK dependency. Hosted UI keeps those flows in
Cognito while the app retains a small OAuth adapter.

### Add a new full-snapshot endpoint

db-sync already has `GET /sync/:graph-id/snapshot/download` and a streaming snapshot
of its DataScript SQLite `kvs` rows. Creating another endpoint or entity snapshot
format would duplicate its permission, snapshot, encryption, and import behavior.

### Send DataScript tx-data over WebSocket

Raw tx-data exposes storage internals, is difficult to version, can contain
intermediate values, and forces every client to reproduce server transaction
semantics. It also makes schema and encryption mistakes more likely.

### Send partial entity patches

Patches are smaller in some cases but require explicit attribute-retraction and
cardinality-many merge rules. Those rules become another form of tx-data. Complete
latest entities are idempotent and unambiguous.

### Maintain a Logseq-specific graph schema

A projection is attractive for UI code but changes types, drops data needed by
references, and creates a second schema that must migrate independently. UI models
may project from the local graph in memory, but the stored graph must use the server
schema.

### Implement sync separately in Swift and Kotlin

Separate platform implementations would duplicate the most correctness-sensitive
state machine and make schema, encryption, and replay behavior diverge. Platform
code provides capabilities to the OCaml core instead.

### Add a separate downstream streaming endpoint

A second streaming or polling endpoint would duplicate authorization, connection lifecycle,
and reconnect behavior. The existing graph WebSocket already provides authenticated
change notifications, so entity replay belongs on that connection.

## Rollout and verification

The snapshot and WebSocket entity payloads are versioned independently from the graph schema.
The new path will be enabled behind a server capability flag and rolled out first to
test graphs, then unencrypted graphs, then encrypted graphs.

The implementation is complete when automated integration tests demonstrate:

- built-in Cognito login, challenge handling, session refresh, logout, expired-token
  reconnect, and graph authorization;
- exact schema and value-type parity after a full snapshot import;
- native OCaml Transit fixtures decode snapshot rows and WebSocket entities produced by
  `logseq-1`, then encode values the server decodes without type changes;
- native OCaml EDN fixtures preserve every schema/configuration value used by the
  app, including UUID and instant tags;
- the same OCaml sync tests run for both Apple and Android core builds, with no sync
  decisions implemented in Swift or Kotlin;
- first-open behavior never exposes a partial graph;
- remote create, update, property retraction, reference change, move, and entity
  deletion produce minimal, latest-state events with no tx-data on the wire;
- the server derives those events solely from the existing DataScript tx-data log,
  existing server transaction numbers, and a captured current database value;
- Logseq can add blocks and modify block properties, while all delete and
  arbitrary transaction requests are rejected by the server;
- duplicate and replayed events are idempotent and cursor gaps trigger reset;
- disconnect/reconnect does not lose committed changes;
- while the API is unreachable, repeated creates and property edits remain
  responsive, survive process termination, preserve their latest state, and synchronize after
  reconnect without duplicate server entities;
- schema changes force atomic re-bootstrap;
- encrypted and unencrypted snapshots converge to the same logical graph data;
- encrypted changes and assets are never plaintext in server logs or wire captures;
- revoked graph access terminates the stream and prevents reconnect;
- iOS background execution never performs semantic polling, preserves pending writes
  when offline or locked, and resumes entity replay from the last committed server
  transaction number.

## References

- `logseq-1/docs/agent-guide/db-sync/protocol.md`
- `logseq-1/deps/db-sync/src/logseq/db_sync/storage.cljs`
- `logseq-1/deps/db-sync/src/logseq/db_sync/worker/handler/sync.cljs`
- `logseq-1/src/main/frontend/worker/sync/download.cljs`
- `datascript-ocaml/examples/logseq_sqlite_storage.ml`
- `logseq/shared/native/logseq_sqlite.ml`
- `logseq/shared/native/logseq_core_ffi.c`
- [melange-transit: native OCaml, js_of_ocaml, and Melange Transit JSON](https://github.com/logseq/melange-transit)
- [melange-edn: native OCaml, js_of_ocaml, and Melange EDN](https://github.com/logseq/melange-edn)
- [Amazon Cognito authorization endpoint](https://docs.aws.amazon.com/cognito/latest/developerguide/authorization-endpoint.html)
- [Amazon Cognito token endpoint](https://docs.aws.amazon.com/cognito/latest/developerguide/token-endpoint.html)
- [Amazon Cognito PKCE](https://docs.aws.amazon.com/cognito/latest/developerguide/using-pkce-in-authorization-code.html)
- [Amazon Cognito User Pool authentication flows](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-authentication-flow-methods.html)
