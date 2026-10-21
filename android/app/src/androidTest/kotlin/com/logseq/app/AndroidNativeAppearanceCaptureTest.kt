package com.logseq.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in native-window capture: no content edits, activity replacement or system touch injection. */
@RunWith(AndroidJUnit4::class)
class AndroidNativeAppearanceCaptureTest {
    @Test fun captureInstalledNativeSurfacesWithoutEditingContent() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("captureAppearance") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = instrumentation.uiAutomation
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir("qa"))
        directory.mkdirs()

        fun find(node: AccessibilityNodeInfo?, match: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
            if (node == null) return null
            if (node.isVisibleToUser && match(node)) return node
            for (index in 0 until node.childCount) find(node.getChild(index), match)?.let { return it }
            return null
        }
        fun node(match: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? =
            find(automation.rootInActiveWindow, match)
        fun waitFor(match: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
            val deadline = SystemClock.uptimeMillis() + 30_000
            do {
                node(match)?.let { return it }
                SystemClock.sleep(150)
            } while (SystemClock.uptimeMillis() < deadline)
            error("Expected native accessibility control did not appear")
        }
        fun click(id: String) {
            check(waitFor { it.viewIdResourceName == id }.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        }
        fun capture(name: String) {
            // A screenshot needs a displayed frame; these are not latency samples.
            SystemClock.sleep(500)
            val bitmap = requireNotNull(automation.takeScreenshot())
            directory.resolve("m3-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            instrumentation.sendStatus(0, Bundle().apply { putString("screenshot", "${directory.absolutePath}/m3-$name.png") })
        }
        fun back() { check(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)) }

        // The host starts the installed activity after instrumentation attaches.
        waitFor { it.viewIdResourceName == "list.outliner" }
        capture("main")
        click("button.sidebar")
        val dismiss = waitFor { n -> n.actionList.any { it.id == AccessibilityNodeInfo.ACTION_DISMISS } }
        capture("drawer")
        check(dismiss.performAction(AccessibilityNodeInfo.ACTION_DISMISS))
        val composerControl = waitFor {
            it.viewIdResourceName == "button.composer.expand" || it.viewIdResourceName == "button.attachment"
        }
        val wasCollapsed = composerControl.viewIdResourceName == "button.composer.expand"
        if (wasCollapsed) click("button.composer.expand")
        try {
            capture("composer")
            click("button.attachment")
            waitFor { it.text?.toString() == "File" }
            capture("attachments")
            back()
            click("button.task-status")
            waitFor { it.text?.toString() == "Todo" }
            capture("status")
            back()
        } finally {
            if (wasCollapsed) click("surface.composer.dismiss")
        }
    }
}
