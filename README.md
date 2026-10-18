# Logseq

Logseq is a native SwiftUI app for iOS and a Kotlin/Jetpack Compose
app for Android. Both clients share an OCaml application model and core, backed by
the OCaml DataScript library and the lui reactive UI layer.

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

```sh
swift build --package-path apple --disable-sandbox --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
(cd android && ./gradlew test)
opam exec --switch=5.5.0 -- dune build @shared/test/runtest
opam exec --switch=5.5.0 -- dune build @shared/native/runtest
./scripts/test-android-e2e-runner.sh
```

Authentication uses Cognito Hosted UI authorization-code flow with PKCE. Apple
uses `ASWebAuthenticationSession`; Android uses Custom Tabs. Tokens are stored
in the platform secure store, so neither client depends on Amplify or the AWS
SDK.

The production Cognito callback is `logseqchat://auth/callback`, separate from
`logseq://` navigation links. Changing it also requires updating the Cognito
app client's allowed callback and sign-out URLs.
