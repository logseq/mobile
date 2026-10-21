"""Exercise the measurement driver against recorded Android command responses."""
import contextlib
import io
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

DRIVER = Path(__file__).resolve().parents[1] / "docs/agent-guide/android-ios-release-qa/2026-10-21/measure-android.py"


class AndroidMeasurementTest(unittest.TestCase):
    def run_driver(self, mode):
        gestures = 0

        def command(args, **kwargs):
            nonlocal gestures
            text = " ".join(args)
            if args[0] == "ps":
                if mode == "host-build" or (mode == "late-host-build" and gestures >= 3):
                    return "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -workspace apple/Project.xcworkspace build\n"
                if mode == "host-recording":
                    return "adb -s emulator-5556 shell screenrecord /sdcard/demo.mp4\n"
                if mode == "idle-gradle":
                    return "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.8.1\n"
                return "python3 measure-android.py\n"
            if "input swipe" in text:
                gestures += 1
                return ""
            if "am start" in text:
                if mode == "launch-timeout":
                    return "Status: timeout\nWaitTime: 18000\n"
                return "Status: ok\nTotalTime: 100\n"
            if "dumpsys window" in text:
                if mode == "api36" and "windows" in args:
                    return "mTopFocusedDisplayId=0\n"
                package = "com.android.launcher3/.Launcher" if mode == "wrong-foreground" else "com.logseq.app/.MainActivity"
                return f"mCurrentFocus=Window{{123 u0 {package}}}\n"
            if "dumpsys activity activities" in text:
                return "topResumedActivity=ActivityRecord{123 u0 com.logseq.app/.MainActivity}"
            if "uiautomator" in text or "hierarchy.xml" in text:
                row = 0 if mode == "stationary" else gestures
                dialog = '<node text="System UI isn’t responding" />' if mode == "anr" else ""
                if mode == "responding-text":
                    dialog = '<node package="com.logseq.app" text="The colleague is responding" />'
                return f'<hierarchy><node package="com.logseq.app" resource-id="list.outliner"><node text="Block {row}" resource-id="outliner.block.{row}" /></node>{dialog}</hierarchy>'
            if "gfxinfo" in text:
                frames = 0 if mode == "zero-frames" else 120
                return f"Total frames rendered: {frames}\nJanky frames: 6\n50th percentile: 12ms\n95th percentile: 32ms\n99th percentile: 48ms\n"
            return ""

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sys, "argv", [str(DRIVER), "--output", directory, "--runs", "1"]), \
                    patch("subprocess.check_output", side_effect=command), patch("time.sleep"), \
                    contextlib.redirect_stdout(io.StringIO()):
                try:
                    runpy.run_path(str(DRIVER), run_name="__main__")
                except SystemExit as error:
                    return str(error)
                return "accepted"

    def test_accepts_moving_foreground_list(self):
        self.assertEqual("accepted", self.run_driver("valid"))

    def test_accepts_api36_display_focus_output(self):
        self.assertEqual("accepted", self.run_driver("api36"))

    def test_accepts_journal_text_about_responding(self):
        self.assertEqual("accepted", self.run_driver("responding-text"))

    def test_rejects_positive_frames_from_wrong_screen(self):
        self.assertIn("foreground", self.run_driver("wrong-foreground"))

    def test_rejects_anr_even_when_app_has_frames(self):
        self.assertIn("dialog", self.run_driver("anr"))

    def test_rejects_nonmoving_list_even_when_app_has_frames(self):
        self.assertIn("movement", self.run_driver("stationary"))

    def test_rejects_zero_frame_scroll(self):
        self.assertIn("no App frames", self.run_driver("zero-frames"))

    def test_rejects_timed_out_launch_with_clear_reason(self):
        self.assertIn("launch", self.run_driver("launch-timeout"))

    def test_rejects_a_concurrent_host_build(self):
        self.assertIn("host build", self.run_driver("host-build"))

    def test_rejects_a_build_that_starts_during_scrolling(self):
        self.assertIn("host build", self.run_driver("late-host-build"))

    def test_rejects_recording_during_measurement(self):
        self.assertIn("recording", self.run_driver("host-recording"))

    def test_accepts_an_idle_gradle_daemon(self):
        self.assertEqual("accepted", self.run_driver("idle-gradle"))


if __name__ == "__main__":
    unittest.main()
