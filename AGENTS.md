# Logseq

Logseq uses native SwiftUI on iOS and Kotlin/Jetpack Compose on Android, backed by an OCaml DataScript core. Canonical setup is in `README.md`.

## Testing

- Do NOT run `swift test` (xctest). It hangs indefinitely in this
  environment (an async Swift Testing case blocks on an XCTWaiter that never
  finishes), wasting many minutes per run. Do not run it.
- Validate OCaml core changes with `dune build @shared/native/runtest`.
- If a Swift compile check is needed, use `swift build --package-path apple` (build only, no test
  run) with sandbox disabled; SwiftPM's own sandbox conflicts with the agent
  sandbox.

## Build system

- Use `dune build @shared/native/runtest` for core validation. The mobile entry object
  also needs platform libraries and FFI symbols supplied by the mobile build.
  Crypto protocol handling lives in `shared/src/logseq/core/platform_crypto.ml`.
  The mobile-only `logseq_crypto_call` FFI declaration lives in
  `shared/src/logseq/native_crypto.ml` so CLI builds do not require mobile symbols.
- Mobile OCaml builds use the thin `scripts/build-mobile-ocaml.sh` Dune wrapper.
  Native module membership lives in `shared/native/dune_modules/*.sexp`. Core sources
  live in `shared/src/logseq/core`; adding one needs no per-file rule.

## Cursor Cloud specific instructions

Cloud Agent VMs are Linux. They cannot run Xcode, the iOS simulator, or `swift test`. Do not try to start those from this environment.

The Linux-runnable surface is the OCaml core in `shared/native/` (inbox capture, DataScript model, RPC, SQLite persistence). There is no in-repo HTTP server; the app's default API is `https://api.logseq.io`. Local sync testing can explicitly override it with `http://127.0.0.1:8787` from the separate Logseq server repository.

### OCaml core

Use the `5.5.0` opam switch (create it if needed with `opam switch create 5.5.0`):

```sh
eval $(opam env --switch=5.5.0)
dune runtest
```

`dune runtest` is the lint/test/build gate here. `dune build` of `logseq_mobile_entry` looks for SQLite via a Homebrew path in `shared/native/dune`; on Linux, either skip that executable or set `LIBRARY_PATH` to your system SQLite lib dir (e.g. `/usr/lib/x86_64-linux-gnu` on Debian/Ubuntu) first.

`opam install . --deps-only` does not apply nested pins from `datascript-ocaml-native`. Pin these first (idempotent):

```sh
opam pin add -n -y melange-edn-core git+https://github.com/logseq/melange-edn.git#main
opam pin add -n -y melange-edn-native git+https://github.com/logseq/melange-edn.git#main
opam pin add -n -y melange-transit-core git+https://github.com/logseq/melange-transit.git#main
opam pin add -n -y melange-transit-native git+https://github.com/logseq/melange-transit.git#main
opam install . --deps-only --yes --with-test
```

`opam init` on this VM must use `--disable-sandboxing`. New shells need `eval $(opam env --switch=5.5.0)` unless `.bashrc` already loads it.

A representative core action is the Swift FFI RPC `dispatch` / `send`, which optimistic-captures a journal block (see `shared/test/logseq/rpc_test.ml` and `dune build @shared/native/runtest`).

- Avoid O(n²) `List` patterns such as `List.concat` and repeated `List.append` on large sequences; when the project already depends on the `rrbvec` package, use `Rrbvec` vectors instead.

### iOS / Android

On a Mac, follow `README.md`: open `apple/Project.xcworkspace`, run the `Logseq App` scheme. Native core builds (`scripts/build-mobile-ios-*.sh`, `scripts/build-android-native.sh`) bootstrap their own cross toolchains under `_build/` via the `scripts/bootstrap-*.sh` helpers. Do not start Android emulators or Maestro from Cloud Agent unless that stack is explicitly in scope.
