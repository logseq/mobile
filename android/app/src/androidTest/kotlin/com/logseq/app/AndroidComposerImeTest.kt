package com.logseq.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in real IME tests against the installed app and the dedicated emulator QA graph. */
@RunWith(AndroidJUnit4::class)
class AndroidComposerImeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val automation get() = instrumentation.uiAutomation
    private var originalDraft: String? = null
    private var wasCollapsed = false
    private var keyboardImage: Bitmap? = null
    private var keyboardBounds = Rect()
    private val draft = "Hello 中文 📝 world"

    private fun find(root: AccessibilityNodeInfo?, match: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (root == null) return null
        root.refresh()
        if (root.isVisibleToUser && match(root)) return root
        for (index in 0 until root.childCount) find(root.getChild(index), match)?.let { return it }
        return null
    }

    private fun node(match: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? =
        automation.windows.firstNotNullOfOrNull { find(it.root, match) }
            ?: find(automation.rootInActiveWindow, match)

    private fun waitFor(timeout: Long = 10_000, match: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val deadline = SystemClock.uptimeMillis() + timeout
        do {
            node(match)?.let { return it }
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        error("Expected installed-app accessibility control did not appear")
    }

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            if (condition()) return
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        error("Expected native IME/window state did not settle")
    }

    private fun control(id: String) = waitFor { it.viewIdResourceName == id }
    private fun field() = control("field.composer")
    private fun click(id: String) { check(control(id).performAction(AccessibilityNodeInfo.ACTION_CLICK)) }
    private fun choose(text: String) {
        automation.waitForIdle(200, 5_000)
        tap(bounds(waitFor { it.text?.toString() == text }))
    }
    private fun tap(target: Rect) {
        val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action,
                target.centerX().toFloat(), target.centerY().toFloat(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { check(automation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
    }
    private fun bounds(node: AccessibilityNodeInfo) = Rect().also(node::getBoundsInScreen)
    private fun setDraft(text: String) {
        check(field().performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }))
        try {
            waitUntil { field().text?.toString() == text }
        } catch (failure: IllegalStateException) {
            error("Draft update did not settle: expected=<$text>, actual=<${field().text}>")
        }
    }

    private fun imeShown(): Boolean = ParcelFileDescriptor.AutoCloseInputStream(
        automation.executeShellCommand("dumpsys input_method"),
    ).bufferedReader().use { "mInputShown=true" in it.readText() }

    private fun back() { check(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)) }

    @Before fun prepareRealComposer() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("verifyComposerIme") == "true")
        assertTrue("This editing fixture is emulator-only", Build.MODEL.startsWith("sdk_gphone"))
        val context = instrumentation.targetContext
        assertEquals("Only the dedicated QA graph may receive test draft edits", "uiregression",
            context.getSharedPreferences("logseq", Context.MODE_PRIVATE).getString("logseq.selectedGraphId", ""))
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        context.startActivity(requireNotNull(context.packageManager.getLaunchIntentForPackage(context.packageName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        waitFor(timeout = 90_000) { it.viewIdResourceName == "list.outliner" }
        val composer = waitFor {
            it.viewIdResourceName == "button.composer.expand" || it.viewIdResourceName == "field.composer"
        }
        wasCollapsed = composer.viewIdResourceName == "button.composer.expand"
        if (wasCollapsed) click("button.composer.expand")
        val input = field()
        originalDraft = if (input.isShowingHintText) "" else input.text?.toString().orEmpty()
        click("field.composer")
        waitUntil(::imeShown)
        setDraft(draft)
        automation.waitForIdle(200, 5_000)
        waitUntil { automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
        automation.windows.first { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .getBoundsInScreen(keyboardBounds)
        keyboardImage = requireNotNull(automation.takeScreenshot())
    }

    @After fun restoreQaDraft() {
        keyboardImage?.recycle()
        keyboardImage = null
        val original = originalDraft ?: return
        if (node { it.text?.toString() == "File" || it.text?.toString() == "Todo" } != null) back()
        val composer = waitFor {
            it.viewIdResourceName == "field.composer" || it.viewIdResourceName == "button.composer.expand"
        }
        if (composer.viewIdResourceName == "button.composer.expand") click("button.composer.expand")
        click("button.task-status")
        waitFor { it.text?.toString() == "Todo" }
        val clear = node { it.text?.toString() == "Clear task status" }
        if (clear != null) tap(bounds(clear)) else back()
        // Material popups finish dismissal asynchronously; restore through the
        // underlying editor only after its accessibility actions are exposed.
        waitUntil { node { it.text?.toString() == "Todo" } == null }
        setDraft(original)
        if (wasCollapsed) click("surface.composer.dismiss")
    }

    private fun assertInputKept(expected: Rect) {
        waitUntil { field().isFocused }
        assertTrue("The real software keyboard stays visible", imeShown())
        assertTrue("The original input retains focus", field().isFocused)
        assertEquals("The composer does not jump when a menu opens", expected, bounds(field()))
        assertEquals(draft, field().text?.toString())
    }

    private fun assertMenuAboveIme(lastItem: String) {
        assertTrue("The native menu does not cover the keyboard",
            bounds(waitFor { it.text?.toString() == lastItem }).bottom <= keyboardBounds.top)
        val before = requireNotNull(keyboardImage)
        val current = requireNotNull(automation.takeScreenshot())
        try {
            val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir("qa"))
            directory.mkdirs()
            directory.resolve("m3-ime-${if (lastItem == "Canceled") "status" else "attachments"}.png")
                .outputStream().use { current.compress(Bitmap.CompressFormat.PNG, 100, it) }
            var changed = 0
            var sampled = 0
            for (y in keyboardBounds.top until keyboardBounds.bottom step 8) {
                for (x in keyboardBounds.left until keyboardBounds.right step 8) {
                    sampled++
                    if (before.getPixel(x, y) != current.getPixel(x, y)) changed++
                }
            }
            assertTrue("The real keyboard remains visibly unchanged beneath the popup: $changed/$sampled pixels",
                sampled > 0 && changed < sampled / 100)
        } finally { current.recycle() }
    }

    @Test fun statusMenuKeepsTheRealKeyboardAndComposerPosition() {
        val before = bounds(field())
        click("button.task-status")
        waitFor { it.text?.toString() == "Todo" }
        // A touch-modal native popup owns accessibility focus until it closes.
        assertTrue("The real software keyboard stays visible while the menu is open", imeShown())
        assertMenuAboveIme("Canceled")
        choose("Todo")
        waitUntil { node { it.text?.toString() == "Todo" } == null }
        assertInputKept(before)
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_X)
        waitUntil { field().text?.toString() == draft + "x" }
    }

    @Test fun attachmentMenuKeepsTheKeyboardAndBackClosesOnlyTheMenu() {
        val before = bounds(field())
        click("button.attachment")
        waitFor { it.text?.toString() == "File" }
        assertTrue("The real software keyboard stays visible while the menu is open", imeShown())
        assertMenuAboveIme("Audio recording")
        back()
        waitUntil { node { it.text?.toString() == "File" } == null }
        assertInputKept(before)
    }

    @Test fun outsideMenuTapPreservesTheKeyboardAndDraft() {
        val before = bounds(field())
        click("button.task-status")
        waitFor { it.text?.toString() == "Todo" }
        tap(before)
        waitUntil { node { it.text?.toString() == "Todo" } == null }
        assertInputKept(before)
    }

    @Test fun openingAMenuDoesNotForceAnAlreadyHiddenKeyboardToOpen() {
        back()
        waitUntil { !imeShown() }
        val before = bounds(field())
        for ((trigger, label) in listOf("button.task-status" to "Todo", "button.attachment" to "File")) {
            click(trigger)
            waitFor { it.text?.toString() == label }
            assertTrue("A menu does not force the keyboard open", !imeShown())
            back()
            waitUntil { node { it.text?.toString() == label } == null }
            assertEquals(before, bounds(field()))
        }
    }

    @Test fun statusSelectionPreservesTheInputCaret() {
        check(field().performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 6)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, 6)
        }))
        click("button.task-status")
        choose("Todo")
        waitUntil { node { it.text?.toString() == "Todo" } == null }
        waitUntil { field().isFocused }
        assertTrue(imeShown())
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_X)
        waitUntil { field().text?.toString() == "Hello x中文 📝 world" }
    }

    @Test fun installedReleaseRendersMathAfterEditingAndKeepsInvalidInputReadable() {
        click("surface.composer.dismiss")
        val initial = waitFor { it.viewIdResourceName == "block.rich.math.rendered" }
        var current = initial.contentDescription.toString()
        val simpleHeight = bounds(initial).height()
        var original: String? = null
        fun editor() = waitFor { it.viewIdResourceName?.startsWith("field.outliner.block.") == true }
        fun openEditor() {
            if (node { it.viewIdResourceName?.startsWith("field.outliner.block.") == true } == null) {
                tap(bounds(waitFor { it.contentDescription?.toString() == current || it.text?.toString() == current }))
            }
        }
        fun replace(text: String) {
            check(editor().performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }))
            waitUntil { editor().text?.toString() == text }
            click("button.outliner.editor.hideKeyboard")
        }
        try {
            openEditor()
            original = editor().text.toString()
            for (formula in listOf("\\frac{1}{\\sqrt{x^2+1}}", "\\sum_{i=1}^{n}i^2", "\\unknowncommand{")) {
                openEditor()
                current = formula
                replace("\$\$$formula\$\$")
                if (formula.startsWith("\\unknowncommand")) {
                    waitFor { it.text?.toString() == formula }
                } else {
                    val rendered = waitFor {
                        it.viewIdResourceName == "block.rich.math.rendered" && it.contentDescription?.toString() == formula
                    }
                    if (formula.startsWith("\\frac")) {
                        assertTrue("The installed Release draws a stacked fraction", bounds(rendered).height() > simpleHeight * 1.5)
                    }
                }
            }
        } finally {
            original?.let {
                openEditor()
                replace(it)
            }
        }
    }

    @Test fun blockTaskButtonVisiblyCyclesStatusAndRetainsItWhenEditingReopens() {
        click("surface.composer.dismiss")
        val title = waitFor { it.text?.toString()?.startsWith("Performance row 001-01") == true }.text.toString()
        tap(bounds(waitFor { it.text?.toString() == title }))
        fun status() = waitFor { it.contentDescription?.toString()?.startsWith("Task: ") == true }
            .contentDescription.toString().removePrefix("Task: ")
        fun cycle(expected: String) {
            tap(bounds(control("button.outliner.editor.task")))
            waitFor { it.contentDescription?.toString() == "Task: $expected" }
        }
        val original = status()
        try {
            repeat(4) {
                if (status() != "None") {
                    cycle(when (status()) { "Todo" -> "Doing"; "Doing" -> "Done"; "Done" -> "None"; else -> "Todo" })
                }
            }
            assertEquals("None", status())
            cycle("Todo")
            SystemClock.sleep(600)
            val button = bounds(control("button.outliner.editor.task"))
            val before = requireNotNull(automation.takeScreenshot())
            try {
                cycle("Doing")
                // Allow the native press indication to finish before comparing the settled control.
                SystemClock.sleep(600)
                val after = requireNotNull(automation.takeScreenshot())
                try {
                    assertEquals("Task changes keep the toolbar anchored", button, bounds(control("button.outliner.editor.task")))
                    assertTrue("Task changes keep the real keyboard open", imeShown())
                    fun darkInk(pixel: Int) = android.graphics.Color.red(pixel) < 180 &&
                        android.graphics.Color.green(pixel) < 180 && android.graphics.Color.blue(pixel) < 180
                    var changed = 0
                    for (y in button.top until button.bottom) for (x in button.left until button.right) {
                        if (darkInk(before.getPixel(x, y)) != darkInk(after.getPixel(x, y))) changed++
                    }
                    val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir("qa"))
                    directory.resolve("block-task-todo.png").outputStream().use { before.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    directory.resolve("block-task-doing.png").outputStream().use { after.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    assertTrue("Todo and Doing have different settled icon strokes: $changed pixels", changed > 100)
                } finally { after.recycle() }
            } finally { before.recycle() }
            cycle("Done")
            click("button.outliner.editor.hideKeyboard")
            tap(bounds(waitFor { it.text?.toString() == title }))
            assertEquals("Done", status())
            cycle("None")
        } finally {
            repeat(4) {
                if (status() != original) {
                    cycle(when (status()) { "Todo" -> "Doing"; "Doing" -> "Done"; "Done" -> "None"; else -> "Todo" })
                }
            }
            click("button.outliner.editor.hideKeyboard")
        }
    }
}
