# Contributing to Logseq Mobile

You can help by reporting a bug, testing a build, improving the docs, or sending a patch. Please follow the [code of conduct](CODE_OF_CONDUCT.md) when taking part.

## Report a bug or propose a change

Search the [Logseq DB issue tracker](https://github.com/logseq/db-test/issues) first. If you open a report, include your device, OS version, and Logseq version and revision from Settings. Describe what you expected, what happened, and the shortest steps to reproduce it. A screenshot or recording helps with visual bugs. Remove personal graph data and credentials from anything you share.

For a larger change, describe the problem and your proposed approach in an issue before starting. For usage questions and workflow ideas, visit the [Logseq community forum](https://discuss.logseq.com/).

## Build from source

Run the commands from the repository root unless a step changes directories. Use the [codebase overview](CODEBASE_OVERVIEW.md) to find the right layer for your change.

### Shared core setup

The native app builds and shared tests need Git, Python 3, opam, OCaml 5.5.0, Dune, and the pinned sources in `duniverse/`. You also need GitHub access to the Logseq dependencies, including LUI. The first build downloads source archives and bootstraps the mobile cross-compiler when needed.

On a fresh opam installation, run `opam init --bare` first. Skip the first command below if you already have the `5.5.0` switch.

```sh
opam switch create 5.5.0
opam install --switch=5.5.0 dune.3.24.2 opam-monorepo.0.3.6
opam exec --switch=5.5.0 -- opam-monorepo pull
```

Fetch the additional Git pins from [`logseq.opam`](logseq.opam) after pulling the lockfile sources. The [CI vendoring action](.github/actions/ocaml-vendor/action.yml) uses the same pins. You can rerun this step after an interrupted fetch. Git must be able to authenticate for any private dependencies.

```sh
grep -oE 'logseq/[A-Za-z0-9_-]+\.git#[A-Za-z0-9._/-]+' logseq.opam | sort -u |
  while IFS= read -r pin; do
    repository=${pin%%#*}
    revision=${pin##*#}
    checkout="duniverse/$(basename "$repository" .git)"
    if [ -d "$checkout" ] && { [ ! -e "$checkout/.git" ] ||
      git -C "$checkout" rev-parse --verify --quiet HEAD >/dev/null; }; then
      continue
    fi
    git init --quiet "$checkout" &&
      git -C "$checkout" fetch --quiet --depth=1 "https://github.com/$repository" "$revision" &&
      git -C "$checkout" checkout --quiet --detach FETCH_HEAD || exit 1
  done
```

For the Linux core gate install the host libraries listed in the [CI workflow](.github/workflows/ci.yml). The [Cloud Agent setup script](scripts/cloud-agent-install.sh) automates dependency setup on the supported Ubuntu environment. On macOS, the [native tests workflow](.github/workflows/native-tests.yml) lists the Homebrew packages used by CI.

### iOS

Use an Apple silicon Mac with Xcode, an installed iOS simulator runtime, and Swift 6.2 or later. Xcode needs GitHub SSH access for the LUI package. Open [`apple/Project.xcworkspace`](apple/Project.xcworkspace) and select the **Logseq App** scheme for Xcode development.

For a full simulator build with the OCaml core and extensions, boot an iPhone simulator and run these commands. If more than one simulator is running, use its UDID in place of `booted`.

```sh
opam exec --switch=5.5.0 -- ./scripts/build-mobile-ios-simulator.sh
xcrun simctl install booted apple/.build/Logseq.app
xcrun simctl launch booted com.logseq.logseq
```

For a physical device, set `LOGSEQ_IOS_BUNDLE_ID`, `LOGSEQ_IOS_PROFILE`, and `LOGSEQ_IOS_DEVICE` in `.logseq-ios-device.env`, then run `opam exec --switch=5.5.0 -- ./scripts/install-mobile-ios-device.sh`. The app, widget, and share extension need matching development profiles for your team and test device. Set `LOGSEQ_IOS_WIDGET_PROFILE` or `LOGSEQ_IOS_SHARE_PROFILE` to choose an extension profile explicitly. To replace a production installation, use `LOGSEQ_IOS_BUNDLE_ID=com.logseq.logseq` with `LOGSEQ_IOS_ALLOW_PRODUCTION_REPLACE=1` and signing from the installed app's team.

Device builds default to Release. Use `LOGSEQ_IOS_BUILD_CONFIGURATION=debug` for an unoptimized build, and use Release when measuring performance. Set `LOGSEQ_APPLE_TOOLCHAIN_ROOT` to share the compiler cache or `LOGSEQ_IOS_TOOLCHAIN_PREFIX` to use a compatible compiler you already built.

The simulator and device scripts share SwiftPM dependencies in `apple/.build`, with build products in separate target directories. Both accept `LOGSEQ_IOS_SWIFT_SCRATCH_PATH` to override that location. The iOS core build retains the current native link snapshot and one previous snapshot per platform.

To work on the LUI backend with a sibling checkout, use `swift package --package-path apple edit lui --path ../lui`. Restore the pinned version with `swift package --package-path apple unedit lui`.

### Android

Use macOS or Linux with Android Studio or the Android SDK command-line tools. Use JDK 21 and install SDK Platform 37, Build Tools 37.0.0, NDK 27.0.12077973, and CMake 3.22.1. Set `ANDROID_HOME` to your SDK directory so the native build can find the NDK, and put the SDK's `platform-tools` directory on your `PATH`. Connect a device with USB debugging enabled or start an emulator.

```sh
cd android
opam exec --switch=5.5.0 -- ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Gradle builds the OCaml shared library automatically. The default ABI is `arm64-v8a`. Add `-PlogseqAndroidAbi=x86_64` to the Gradle command for an x86-64 emulator. Use `:app:assembleRelease` for a release APK, `:app:bundleRelease` for an app bundle, and `:app:assembleProfile` for the APK used by Android end-to-end tests.

## Run the checks

Pick the checks that cover the code you changed.

| Area | Command from the repository root |
| --- | --- |
| Shared OCaml core | `opam exec --switch=5.5.0 -- dune build @shared/native/runtest` |
| iOS Swift model | `python3 scripts/test-swift-model-suite.py` |
| iOS UI | `python3 scripts/test-swift-ui-suite.py` after the simulator build |
| Android JVM | `(cd android && ./gradlew test -PlogseqRequireNativeCore=false)` |
| Android E2E runner | `./scripts/test-android-e2e-runner.sh` |

Use the Swift scripts directly. The XCTest bridge used by `swift test` hangs in this repository. For the full device and simulator suites, see the [native test workflow](.github/workflows/native-tests.yml) and the [Maestro workflow](.github/workflows/e2e.yml).

<details>
<summary>Targeted iOS and Android checks</summary>

- **iOS recording Live Activity.** Boot a simulator, build with `LOGSEQ_IOS_ENABLE_TESTING=1 ./scripts/build-mobile-ios-simulator.sh`, and run `python3 scripts/test-ios-recording-live-activity.py`. It checks archived Lock Screen and Dynamic Island layouts.
- **iPhone Duo toolbar.** Use Xcode 27.1 or later and the same testing build. Run `LOGSEQ_RUNTIME_CHECK_TIMEOUT=65 python3 apple/Tests/UI/run-simulator-runtime-check.py apple/Tests/UI/duo-toolbar-layout.swift DuoToolbarLayoutCheck` and change poses in Device Hub during the check. With multiple booted simulators, set `LOGSEQ_IOS_SIMULATOR=<UDID>`. Set `SIMCTL_CHILD_LOGSEQ_DUO_REQUIRE_POSE_CHANGE=1` to require both toolbar axes, `SIMCTL_CHILD_LOGSEQ_DUO_CHECK_INTERACTIONS=1` to check focus and draft retention, or `SIMCTL_CHILD_LOGSEQ_DUO_REGULAR_WIDTH=1` to exercise the expanded split view. Set `LOGSEQ_RUNTIME_CHECK_ARTIFACTS` to retain screenshots. The [UI runtime checks](apple/Tests/UI) also cover search dismissal, page navigation, appearance, and PDF downloads and annotations.
- **iOS composer menus.** [Install the Maestro CLI](https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli) and confirm that `maestro --version` works in your terminal. After a Release simulator build, run `LOGSEQ_IOS_CONFIGURATION=release python3 scripts/test-ios-native-menus.py`. Add `--hit-testing` to cover focus and single-tap file selection. This Maestro check runs without an account or server.
- **iOS sync recovery.** Run `python3 scripts/test-ios-sync-recovery.py` for the WebSocket recovery checks, or add `--simulator` to use the iOS Foundation runtime.
- **Android instrumented Release tests.** From `android/`, run `./gradlew :app:assembleRelease :app:assembleReleaseAndroidTest -PlogseqTestBuildType=release`. Sign both APKs with the same certificate before installing. The Release test build applies the app's R8 mapping.
- **Capture translations.** After editing [`CaptureLocalizations.json`](apple/Sources/Logseq/Resources/CaptureLocalizations.json), run `python3 scripts/generate-capture-localizations.py`. Use `--check` to verify coverage and generated output.

</details>

### Test sync locally

For randomized multi-client sync checks, use Node.js 24 or later and a separate checkout of the [main Logseq repository](https://github.com/logseq/logseq). Build the CLI bundle and `db-worker-node` from the same revision, then build `db-sync-node` from that checkout's `deps/db-sync` directory.

```sh
opam exec --switch=5.5.0 -- dune build shared/native/logseq_sync_client.exe
node scripts/local-sync-fixture.cjs /absolute/path/to/logseq-master
```

In a second terminal, use the fixture path printed by the server.

```sh
node scripts/run-local-sync-stress.cjs /absolute/path/to/fixture.json 20261027 320 /absolute/path/to/logseq-master
```

The disposable fixture runs the real sync server and checks that the mobile client, CLI, and a fresh server snapshot converge. Runs of at least 177 iterations also exercise offline edits, process crashes, server restarts, and lost acknowledgements. The fixture keeps the seed, operation trace, summary, and confirmed UI snapshot. Stop it with Ctrl-C.

To check the vendored normalization and replay code, run `python3 scripts/vendor-dev-sync.py ../logseq-1 --check` against the pinned Logseq checkout. Drop `--check` to regenerate it. Platform adapters live in [`scripts/vendor-dev-sync-platform.ml`](scripts/vendor-dev-sync-platform.ml).

## Send a pull request

Branch from `main` and keep the patch focused on one change. In your pull request, explain what changed and why, link the relevant issue, and list the checks you ran. For visible changes, include a screenshot or short recording and the platform you tested.

## Publish a tester build

- **iOS.** Run [Build-iOS](.github/workflows/build-ios-release.yml) from `main` to sign and upload to TestFlight. It distributes to **Mobile Testers** and submits the build for Beta App Review when required. Choose `testflight-distribution=internal` to send the build only to internal groups.
- **Android.** Run [Build-Android](.github/workflows/build-android.yml) for signed APK and AAB artifacts. The default Play track is **Closed testing (alpha)**. Choose `play-track=internal` for internal testing and `git-ref` to select the branch or tag. Start a new run to publish newer code. CI generates a version code and checks 16 KB native library alignment before upload. Local builds default to version code `1`, which you can override with `-PlogseqVersionCode=123`.
- **Release notes.** Update [`release-notes/<version>/`](release-notes) with `ios.txt` for TestFlight's **What to Test** and `android.txt` for Google Play. Keep the Android notes within 500 characters.
- **Crash reporting.** Release builds report to the corresponding Sentry projects. Both workflows use `SENTRY_AUTH_TOKEN` to upload symbols. To smoke-test reporting in the Sentry development environment, use `-PlogseqSentryDebug=true` on Android or launch the iOS simulator app with `SIMCTL_CHILD_LOGSEQ_SENTRY_DEBUG=1`.

<details>
<summary>Google Play setup for the first upload</summary>

Configure `ANDROID_KEYSTORE` with the base64-encoded upload keystore and `ANDROID_KEYSTORE_PASSWORD` with the keystore and key password. For automated publishing, set `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` to the service account credentials. Enable the Google Play Android Developer API for that account and grant **View app information** and **Release apps to testing tracks** in Play Console.

Run the workflow with `upload-play=false` for the first upload. Download the signed AAB from `logseq-android-builds` and upload it in Play Console to register `com.logseq.logseq`, configure Play App Signing, and publish the first internal release. Later workflow runs can publish with `upload-play=true` and `release-status=completed`. Use `release-status=draft` to upload without rolling out.

</details>
