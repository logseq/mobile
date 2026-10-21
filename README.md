# Logseq

Logseq is a native SwiftUI app for iOS and a Kotlin/Jetpack Compose
app for Android. Both clients share an OCaml application model and core, backed by
the OCaml DataScript library and the lui reactive UI layer.

iOS and Android share the app version in `version.xcconfig`. Android builds,
the iOS build scripts, and the TestFlight lane embed the mobile repository's
current Git commit as the settings revision.

Shared core sources live in `shared/src/logseq/core`, with executable entry points
in `shared/src/logseq/entry`. The `shared/native` directory contains Dune configuration and
native platform bridges; generated OCaml stays under `_build`. Core tests live
in `shared/test/logseq`, one alcotest suite per core module. The core test gate also builds the seed and live-sync executables.

## Repository layout

- `apple/`: Swift package, app, extensions, Xcode workspace, and Apple tests.
- `android/`: Kotlin/Jetpack Compose Android app and its platform integration.
- `shared/src/`: OCaml application and core sources.
- `shared/test/`: OCaml test suites.
- `shared/native/`: Dune configuration and native bridges.
- `tests/e2e/`: Maestro flows and fixtures.
- `scripts/`: build and validation commands, run from the repository root.
- `docs/`: design and development documentation.
- `duniverse/`: fetched OCaml dependencies; ignored by Git.

## iOS

Open `apple/Project.xcworkspace` and run the `Logseq App` scheme in Xcode.

The Apple backend comes from the `LUIAppleBackendStatic` product of the LUI
Swift package, pinned by Git revision in `apple/Package.swift` and `apple/Package.resolved`.
Use Swift 6.2 or later. Backend changes belong in the LUI repository.

The first iOS build creates a deployment-targeted OCaml 5.5 toolchain under
`_build/apple-toolchains`. Native dependencies and core objects are keyed by
compiler, target, and source fingerprints, so later builds reuse them. Set
`LOGSEQ_APPLE_TOOLCHAIN_ROOT` to share the toolchain cache, or provide
`LOGSEQ_IOS_TOOLCHAIN_PREFIX` to use an existing compatible compiler
directly.

`scripts/install-mobile-ios-device.sh` uses signing and device settings from
`.logseq-ios-device.env`. To replace an existing Logseq installation, use
`LOGSEQ_IOS_BUNDLE_ID=com.logseq.logseq` and explicitly set
`LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE=1`, with a profile and signing identity
from the same Apple team as the installed app.

Device builds embed both the widget and share extensions. Matching development
profiles are selected automatically; set `LOGSEQ_IOS_WIDGET_PROFILE` or
`LOGSEQ_IOS_SHARE_PROFILE` to select a profile explicitly.

## Android

Android is a standard Gradle project:

```sh
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Release builds use `:app:assembleRelease` / `:app:bundleRelease`. The e2e
profile APK used by `scripts/test-android-e2e.sh` is `:app:assembleProfile`
(`app/build/outputs/apk/profile/app-profile.apk`). JVM unit tests run with
`./gradlew test`.

The OCaml core shared library is built separately by
`scripts/build-android-native.sh` (per ABI), which installs
`liblogseq_core.so` into `android/app/src/main/jniLibs/<abi>`; the Gradle
`buildAndroidNativeCore` task invokes it automatically (set
`-PlogseqRequireNativeCore=false` to compile Kotlin without it).

The Android host includes Capture and Journal app shortcuts, Capture and
Today’s Journal home-screen widgets, inbound sharing, deep links, native
authentication, media services, and the OCaml core JNI library.

## iPhone shortcuts and widgets

Long-press the app icon for Voice and Quick Add.
The Shortcuts app exposes Quick Add, Record Audio, Today's Journal, and Capture
to Journal (text input). The Quick Capture home-screen widget includes recording
and capture buttons; Today's Journal opens the journal. On iOS 18 and later,
Quick Add and Record Audio are also available in Control Center and on the Lock
Screen. These entry points open the existing composer and recorder, including
when the app needs to launch first.

Both iOS build scripts include App Intents metadata and the widget extension.
Device builds select a compatible development profile for `com.logseq.logseq.shortcuts`;
set `LOGSEQ_IOS_WIDGET_PROFILE` in `.logseq-ios-device.env` to specify one.
The extension and app must be signed by the same team, and their profiles must
include the target device.

## Testing

Do not run `swift test` in this repository because the XCTest bridge hangs in
the current environment. Use the supported gates instead:
Run the model suite without that bridge using `python3 scripts/test-swift-model-suite.py`.
It builds `LogseqModelTests` and launches Swift Testing directly.
Run the native UI suite in a simulator app host with `python3 scripts/test-swift-ui-suite.py`
after building the simulator core. This also invokes Swift Testing directly.
Run `LOGSEQ_IOS_CONFIGURATION=release python3 scripts/test-ios-native-menus.py`
after a Release simulator build to exercise native composer menus with Maestro.
It checks every attachment presenter, recording import, repeated cancellation,
all task statuses, and the search close button without a server or credentials.
Add `--hit-testing` to check independent composer focus targets and the first
single-tap File selection above the active keyboard.
Check WebSocket peer closures, transport cancellation, and owner-task cancellation
with `python3 scripts/test-ios-sync-recovery.py`; add `--simulator` to run the
same real-socket checks with the iOS Foundation runtime. The simulator run also
checks that automatic pending uploads preserve the foreground subscription while
an explicit Sync now can restart it.

```sh
swift build --package-path apple --disable-sandbox --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
(cd android && ./gradlew test)
opam exec --switch=5.5.0 -- dune build @shared/test/runtest
opam exec --switch=5.5.0 -- dune build @shared/native/runtest
./scripts/test-android-e2e-runner.sh
```

For randomized multi-client sync checks, use Node.js 24 or newer. Build the current CLI bundle and
`db-worker-node` in a separate Logseq master checkout, and build `db-sync-node`
from its `deps/db-sync` directory. The CLI and worker must have matching revisions.
Then build this repository's `shared/native/logseq_sync_client.exe` target and run:

```sh
node scripts/local-sync-fixture.cjs /absolute/path/to/logseq-master
# In another terminal, use the fixture path printed above:
node scripts/run-local-sync-stress.cjs /absolute/path/to/fixture.json 20261027 320 /absolute/path/to/logseq-master
```

The fixture runs the real local sync server with a disposable database, JWT issuer,
and isolated CLI configuration. The driver uses the real mobile session and CLI,
generates all mobile semantic operation types plus capture, transcription, and
flashcard reviews, and checks actual attachment uploads. Runs of at least 177
iterations also exercise offline edits, process crashes, server restart, and lost
HTTP acknowledgements. Successful runs require empty pending queues and identical
UUID-normalized synced datoms in the mobile database, CLI database, and a fresh
server snapshot. The CLI comparison excludes its derived `block/refs` and local
`block/tx-id`, matching the server checksum exclusions; the mobile/server comparison
includes every datom. Each run retains its seed, operation trace, summary, and confirmed UI
snapshot under the temporary fixture directory. Stop the fixture with Ctrl-C.

Authentication uses Cognito Hosted UI authorization-code flow with PKCE. Apple
uses `ASWebAuthenticationSession`; Android uses Custom Tabs. Tokens are stored
in the platform secure store, so neither client depends on Amplify or the AWS
SDK.

Sync uses dev's `pull` / `pull/ok` journal and `tx/batch` protocol. Only canonical
server journal rows enter the persisted graph; pending edits store normalized
datoms and replay on a display DB without durable storage. Snapshot bootstrap
reads its cursor through the existing pull endpoint and its schema from the
snapshot database, without requiring extra snapshot metadata or response headers.

The normalization and overlay replay algorithms in `Dev_sync` are extracted
verbatim from Logseq dev commit `53952776ef10805cba03009d444cf021f0d2c3ce`.
`python3 scripts/vendor-dev-sync.py ../logseq-1 --check` verifies the pinned source;
the same command without `--check` regenerates it. Mobile platform adapters are
kept in `scripts/vendor-dev-sync-platform.ml`.

The Cognito callback is `logseq://auth/callback`; sign-out uses
`logseq://auth/logout`. Both URLs are registered in the Cognito app client's
allowed callback and sign-out URLs.
