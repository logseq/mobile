#!/usr/bin/env python3
"""Check the real Gradle configuration used to build and package native ABIs."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
INIT_SCRIPT = """
gradle.projectsEvaluated {
    def app = gradle.rootProject.project(":app")
    app.tasks.register("verifyNativeAbiConfiguration") {
        doLast {
            def abi = System.getenv("LOGSEQ_TEST_EXPECTED_ABI")
            def android = app.extensions.getByName("android")
            def nativeBuild = app.tasks.getByName("buildAndroidNativeCore")
            def expectedLibrary = app.file("src/main/jniLibs/${abi}/liblogseq_core.so")
            def errors = []
            if (android.defaultConfig.ndk.abiFilters != [abi] as Set) {
                errors.add("APK ABIs ${android.defaultConfig.ndk.abiFilters} must match core ABI ${abi}")
            }
            if (nativeBuild.outputs.files.files != [expectedLibrary] as Set) {
                errors.add("Core output ${nativeBuild.outputs.files.files} must be ${expectedLibrary}")
            }
            if (!errors.isEmpty()) throw new GradleException(errors.join("\\n"))
        }
    }
}
"""


class NativePackagingTests(unittest.TestCase):
    def verify_configuration(self, expected, environment_abi=None, property_abi=None):
        env = os.environ.copy()
        env.pop("LOGSEQ_ANDROID_ABI", None)
        env.pop("ORG_GRADLE_PROJECT_logseqAndroidAbi", None)
        env["LOGSEQ_TEST_EXPECTED_ABI"] = expected
        if environment_abi is not None:
            env["LOGSEQ_ANDROID_ABI"] = environment_abi
        with tempfile.TemporaryDirectory(prefix="logseq-native-packaging-") as directory:
            init_script = Path(directory) / "verify.gradle"
            init_script.write_text(INIT_SCRIPT)
            command = [str(ROOT / "android/gradlew"), "-p", str(ROOT / "android"),
                       "--quiet", "--console=plain", "--init-script", str(init_script),
                       "-PlogseqRequireNativeCore=false", ":app:verifyNativeAbiConfiguration"]
            if property_abi is not None:
                command.append(f"-PlogseqAndroidAbi={property_abi}")
            result = subprocess.run(command, env=env, cwd=directory, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_default_build_packages_arm64_core(self):
        self.verify_configuration("arm64-v8a")

    def test_ci_environment_selects_x86_core_and_apk(self):
        self.verify_configuration("x86_64", environment_abi="x86_64")

    def test_gradle_property_overrides_environment(self):
        self.verify_configuration("arm64-v8a", environment_abi="x86_64",
                                  property_abi="arm64-v8a")

    def test_gradle_property_selects_x86_core_and_apk(self):
        self.verify_configuration("x86_64", property_abi="x86_64")


if __name__ == "__main__":
    unittest.main()
