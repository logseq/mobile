pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// The Kotlin/Jetpack Compose LUI backend is consumed as an included
// module from the pinned duniverse/lui checkout used by the OCaml core.
// A sibling LUI checkout is a fallback for development. The module resolves
// plugins from this build's classpath (AGP 9 + builtInKotlin).
val luiModuleDir = requireNotNull(
    listOf(
        File(rootDir, "../duniverse/lui/platform/android/lui"),
        File(rootDir, "../../lui/platform/android/lui"),
    ).firstOrNull { it.isDirectory && File(it, "build.gradle.kts").isFile }
) {
    "Expected a logseq/lui checkout at ../lui or duniverse/lui with platform/android/lui"
}

include(":lui")
project(":lui").projectDir = luiModuleDir

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

include(":app")
