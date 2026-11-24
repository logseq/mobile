plugins {
    id("com.android.test")
}

// Records the app's Baseline Profile. Gradle's connected tasks uninstall the
// app afterwards, so run the generator with scripts/generate-android-baseline-profile.sh,
// which keeps a signed-in graph on the device.
android {
    namespace = "com.logseq.logseq.baselineprofile"
    compileSdk { version = release(37) { minorApiLevel = 0 } }

    defaultConfig {
        minSdk = 28
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        create("benchmark") {
            isDebuggable = true
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }

    targetProjectPath = ":app"
    experimentalProperties["android.experimental.self-instrumenting"] = true
}

androidComponents {
    beforeVariants { variant -> variant.enable = variant.buildType == "benchmark" }
}

dependencies {
    implementation("androidx.test.ext:junit:1.3.0")
    implementation("androidx.test:runner:1.7.0")
    implementation("androidx.test.uiautomator:uiautomator:2.4.1")
    implementation("androidx.benchmark:benchmark-macro-junit4:1.5.0")
}
