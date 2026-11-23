# Codebase overview

Logseq Mobile uses SwiftUI on iOS and Jetpack Compose on Android. The two apps share an OCaml application model, DataScript graph logic, and LUI's reactive views. The native hosts render the app and provide platform services such as recording, sharing, secure storage, and PDF viewing.

## Where to look

| For changes to… | Start here |
| --- | --- |
| iOS screens and platform services | [`apple/Sources/Logseq`](apple/Sources/Logseq) |
| iOS app, widgets, and share extension | [`apple/App`](apple/App) |
| Android screens and platform services | [`android/app/src/main`](android/app/src/main) |
| Shared state, screens, and app actions | [`app.ml`](shared/src/logseq/app.ml), [`model.ml`](shared/src/logseq/model.ml), and [the shared view modules](shared/src/logseq) |
| Graph transactions, queries, capture, or sync | [`shared/src/logseq/core`](shared/src/logseq/core) |
| Native runtime and executable entry points | [`shared/native`](shared/native) and [`shared/src/logseq/entry`](shared/src/logseq/entry) |
| Tests and fixtures | [Shared core](shared/test), [Apple](apple/Tests), [Android JVM](android/app/src/test), [Android device](android/app/src/androidTest), and [Maestro](tests/e2e) |
| Build and release tooling | [`scripts`](scripts), [GitHub Actions workflows](.github/workflows), and [shared app version](version.xcconfig) |

## Follow a journal capture

1. The native app hands the action to the OCaml runtime through a native bridge. On Apple, start at the [C ABI](apple/Sources/LogseqCoreABI). On Android, start at the [JNI wrapper](android/app/src/main/kotlin/com/logseq/logseq/NativeCore.kt).
2. The [mobile entry point](shared/src/logseq/entry/logseq_mobile_entry.ml) connects the native host to shared application state. The [RPC session](shared/src/logseq/core/rpc_session.ml) handles graph operations. [RPC tests](shared/test/logseq/rpc_test.ml) show how a journal capture behaves through this interface.
3. The [mobile graph](shared/src/logseq/core/mobile_graph.ml) combines the local mirror with pending edits for display, so a capture can appear immediately. The sync session submits queued changes when connected and applies accepted server transactions to the canonical local graph.

## Graph storage and sync

The local graph uses DataScript with SQLite persistence. Canonical server journal rows update the persisted graph. Pending edits live in a durable queue and replay over the canonical graph to produce the view you see.

Graph edits go over a WebSocket using `pull` / `pull/ok` and `tx/batch`. Snapshots and attachments use HTTP. Batches preserve order and are capped at 50 transactions and 1,000,000 UTF-8 bytes per message. Deletes are sent separately. A partial rejection settles the accepted prefix, records the failure, and leaves the remainder pending. PDF highlights are `Pdf-annotation` blocks that use the same persistence and sync path. The [graph sync ADR](docs/adr/001-real-time-graph-sync.md) and [outliner ADR](docs/adr/002-mobile-outliner-mode.md) explain the design in more detail.

The server lives under `deps/db-sync` in the [main Logseq repository](https://github.com/logseq/logseq). The mobile app defaults to `https://api.logseq.io`. See the [local sync guide](CONTRIBUTING.md#test-sync-locally) for a disposable fixture.

The shared LUI sign-in forms use an OCaml Cognito state machine. Native adapters call the User Pools JSON API and store tokens in Keychain on Apple and Keystore-backed encrypted storage on Android. Configuration uses a region, user pool ID, and public app client ID. The client enables `ALLOW_USER_PASSWORD_AUTH`, refreshes with `GetTokensFromRefreshToken`, and signs out with `RevokeToken`.

## Build boundaries

- Dune compiles the shared OCaml core. [Native module lists](shared/native/dune_modules) define platform membership, and [the mobile build wrapper](scripts/build-mobile-ocaml.sh) selects the target compiler. Generated sources and objects live under `_build`.
- [The Swift package](apple/Package.swift) pins `LUIAppleBackendStatic`. On Android, Gradle builds `liblogseq_core.so` for the selected ABI and packages it with the app.
- English natural-language dates use chrono-node, and calculator blocks use BigNumber.js. Each creates its own QuickJS runtime on demand. The first core build fetches the [checksum-pinned sources](shared/native/nlp/dependencies.json) and caches their archives under `$XDG_CACHE_HOME/logseq/native-dependencies` (typically `~/.cache/logseq/native-dependencies`).
- Both apps read their version from [`version.xcconfig`](version.xcconfig). Builds also embed the Git revision shown in app settings.

See the [contributing guide](CONTRIBUTING.md) for setup and test commands.
