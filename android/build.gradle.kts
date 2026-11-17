plugins {
    id("com.android.application") version "9.4.1" apply false
    id("com.android.library") version "9.4.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
    id("io.sentry.android.gradle") version "6.27.0" apply false
    // Resolved on this build's classpath so the included :lui module
    // (../lui/platform/android/lui) can apply it; paparazzi tests stay
    // disabled here — see the withType<Test> block below.
    id("app.cash.paparazzi") version "2.0.0-alpha05.1" apply false
}

// :lui is the real LUI Kotlin backend included from ../lui/platform/android.
// Its own test suite (paparazzi screenshot tests) needs the standalone
// platform/android build — disable it here so ./gradlew test only runs
// the app's tests.
project(":lui").tasks.withType<Test>().configureEach {
    enabled = false
}
