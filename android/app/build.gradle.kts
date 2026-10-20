import java.net.URLClassLoader

plugins {
    id("com.android.application")

    id("org.jetbrains.kotlin.plugin.compose")
}

// The OCaml core .so is produced by scripts/build-android-native.sh; it
// takes minutes (and needs the OCaml cross toolchain), so Gradle calls it
// at most once per ABI unless the script is re-run.
val repoRoot = rootDir.parentFile
val buildRevision = providers.exec {
    workingDir(repoRoot)
    commandLine("git", "rev-parse", "--short=8", "HEAD")
}.standardOutput.asText.map(String::trim)
val androidAbi = providers.gradleProperty("logseqAndroidAbi").orNull ?: "arm64-v8a"
val nativeLibrary = File("src/main/jniLibs/$androidAbi/liblogseq_core.so")

val buildAndroidNativeCore = tasks.register("buildAndroidNativeCore") {
    group = "build"
    description = "Builds liblogseq_core.so for $androidAbi via scripts/build-android-native.sh"
    inputs.files(
        "src/main/cpp/CMakeLists.txt",
        "src/main/cpp/logseq_jni.c",
    )
    inputs.dir(File(repoRoot, "shared"))
    inputs.files(File(repoRoot, "scripts/build-android-native.sh"))
    outputs.file(nativeLibrary)
    doLast {
        val output = providers.exec {
            workingDir(repoRoot)
            environment("LOGSEQ_ANDROID_ABI", androidAbi)
            commandLine("bash", "scripts/build-android-native.sh")
        }
        output.result.get().assertNormalExitValue()
    }
}

// The native .so is only required when assembling an APK to run on a
// device/emulator; JVM unit tests and lint must work without it. Allow
// developers (and CI running `test`) to skip it.
val nativeCoreRequired =
    providers.gradleProperty("logseqRequireNativeCore").map(String::toBoolean).orElse(true)

android {
    namespace = "com.logseq.app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "com.logseq.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "2.0.2"
        buildConfigField("String", "GIT_REVISION", "\"${buildRevision.get()}\"")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        // E2E variant: debuggable like the previous profile APK the Maestro
        // flows install via scripts/test-android-e2e.sh.
        create("profile") {
            initWith(getByName("debug"))
            matchingFallbacks += "debug"
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            // The JNI shim dlopen()s liblogseq_core.so by soname, so
            // native libraries must be extracted onto the device fs.
            useLegacyPackaging = true
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }

    sourceSets["main"].jniLibs.directories.add("src/main/jniLibs")
}

tasks.named("preBuild") {
    if (nativeCoreRequired.get()) {
        dependsOn(buildAndroidNativeCore)
    }
}



dependencies {
    // The real Kotlin LUI backend, included from
    // ../lui/platform/android/lui — see settings.gradle.kts.
    implementation(project(":lui"))

    // Newest BOM compatible with compileSdk 36: BOM 2026.08+ maps compose to
    // 1.12.x, whose minCompileSdk=37 (android-37 is not on the stable channel).
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.foundation:foundation-layout")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.runtime:runtime")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose")
    implementation("androidx.browser:browser:1.10.0")
    implementation("com.google.mlkit:genai-speech-recognition:1.0.0-alpha1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.json:json:20260814")

    testImplementation("org.json:json:20260814")
    testImplementation("junit:junit:4.13.2")

    androidTestImplementation("org.json:json:20260814")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.06.01"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}


