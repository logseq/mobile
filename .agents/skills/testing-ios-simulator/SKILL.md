---
name: testing-ios-simulator
description: Build and launch the Logseq iOS app in an iOS simulator on macOS arm64 (Xcode + cross OCaml toolchain), including the iOS SDK function-detection pitfalls in bootstrap-ios-ocaml.sh.
---

# Logseq iOS Simulator Build & Launch

## Prerequisites
- macOS arm64 with Xcode installed (`xcodebuild -version` works).
- opam switch `5.5.0` with dune (`opam exec --switch=5.5.0 -- dune --version`).
- An iOS simulator: `xcrun simctl list devices available | grep iPhone`; boot one with
  `xcrun simctl boot <UDID>`.

## Build steps
1. `scripts/bootstrap-ios-ocaml.sh simulator` — builds host + cross OCaml 5.5.0 under
   `_build/apple-toolchains/ios/` (long first run; stamps skip rebuilds).
2. `scripts/build-mobile-ios-simulator.sh` — builds `shared/native/logseq_mobile_entry.exe.o`
   via dune context `ios_simulator`, then `swift build` (product `LogseqShell`),
   xcodebuild for the share/widget extensions, and assembles+codesigns
   `.build/Logseq.app`. Note: the script can exit non-zero at the end even when all
   artifacts are produced correctly — re-running it (incremental) and checking for
   `.build/Logseq.app/Logseq` is the practical check.
3. `xcrun simctl install booted .build/Logseq.app`
4. `xcrun simctl launch booted com.logseq.logseq` → prints `com.logseq.logseq: <pid>`;
   verify the process stays alive via
   `xcrun simctl spawn booted launchctl list | grep logseq`.
5. Screenshot: `xcrun simctl io booted screenshot out.png`.

## Pitfalls
- `bootstrap-ios-ocaml.sh` host `./configure` must pass `--without-zstd`, else
  zstd-compressed .cmi files break the LG toolchain later (LG2000 errors).
- Cross-compiling OCaml for iOS: configure's link-only `AC_CHECK_FUNC` detects symbols
  (pipe2, dup3, accept4, execvpe, prctl, secure_getenv, __secure_getenv) that link but
  are NOT declared in the iOS SDK headers → "call to undeclared function" errors under
  modern clang. Fix by passing `ac_cv_func_<name>=no` to the target configure. Check for
  more with a compile probe:
  `xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot <sdk> -c t.c`
  where t.c calls the function after including the SDK headers.
- First launch may show a local-network permission alert; dismiss it via Simulator UI.
- The app opens to a "Logseq / Sign in" screen (Cognito hosted UI); going past it
  requires credentials.
- `duniverse/` pulls only the lockfile dirs (129). The `logseq/*` pins NOT vendored
  (`datascript-ocaml`, `lg`, `lui`, `mldoc`, `persistent-sorted-set-ocaml`,
  `signal-lg`) must be cloned manually into `duniverse/` at the SHAs listed in
  `logseq.opam` — same loop as `.github/workflows/e2e.yml`. A fresh
  `opam-monorepo pull` wipes these dirs, so re-clone them after each pull.
- `scripts/build-mobile-ocaml.sh` regenerates `_build/dune-workspace.mobile` from
  `dune-workspace.mobile`; set `LOGSEQ_OPAM_SWITCH=5.5.0` when running outside
  `opam exec`.

## Sheet interaction checks

- Follow the existing journal calendar sheet for compact utility presentations. Result-view filter and sort sheets should open partially, with expansion available for longer lists (`medium,large` in the LUI wire format), and retain native navigation actions and swipe dismissal.
- The custom Logseq palette must reach the complete modal surface, including navigation, list background, and grouped rows. LUI sheets render outside the scoped node tree; propagate the ancestor-resolved semantic colors into their content. Avoid unconditional system grouped backgrounds when a theme supplies a background.
- Use a simulator runtime check to inspect the actual presented frame and screenshot colors in both appearances. For dark Logseq settings, the surrounding sheet background should match the graph background token (`#002D38`), with themed elevated rows. Also exercise Cancel, Done, and scrolling without changing filter/sort semantics.
- Use `apple/Tests/UI/run-simulator-runtime-check.py` for native checks; do not run `swift test` in this repository.

## Maestro e2e (test-ios-e2e-suite.sh)
- Install Maestro: `curl -fsSL https://get.maestro.mobile.dev | bash` → `~/.maestro/bin`.
- The e2e flows hit the app's sync server at `http://127.0.0.1:8787`. That server is
  `deps/db-sync` in the `logseq` repo, and it MUST run from the
  `feature/native-mobile-app` branch (the canonical `../logseq-1` checkout) — the app
  requires `schema-version` in the `/sync/<id>/snapshot/download` response, which only
  exists there (`main` returns without it → "Add sync graph" fails with
  `NSURLErrorDomain Code=-1017`). Setup:
  `cd ../logseq-1/deps/db-sync && pnpm install && clojure -M:cljs release db-sync-node`
  (needs `JAVA_HOME=$(/usr/libexec/java_home -v 21)`), then
  `DB_SYNC_PORT=8787 DB_SYNC_DATA_DIR=~/db-sync-data ./start.sh`;
  health check `curl http://127.0.0.1:8787/health`.
- Run: `LOGSEQ_IOS_SKIP_BUILD=1 LOGSEQ_E2E_USERNAME=<u> LOGSEQ_E2E_PASSWORD=<p> ./scripts/test-ios-e2e-suite.sh smoke`
  (4 flows: capture-responsive, cold-start-composer, search-status-regression, sidebar).
- `scripts/test-ios-e2e.sh` wipes the app data container between flows; `<container>/tmp`
  must be recreated (the script does `mkdir -p`) or the OCaml core crashes writing the
  initial graph snapshot via `Filename.temp_file` (`Sys_error ...tmp/logseq-initial-*.snapshot`).

## Devin Secrets Needed
- `LOGSEQ_TEST_USERNAME` / `LOGSEQ_TEST_PASSWORD` for hosted sign-in and e2e.
