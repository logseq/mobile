package com.logseq.logseq

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real installed-app input latency; run only with a backed-up emulator fixture. */
@RunWith(AndroidJUnit4::class)
class AndroidEnterPerformanceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val automation get() = instrumentation.uiAutomation

    private fun find(root: AccessibilityNodeInfo?, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (root == null) return null
        if (root.isVisibleToUser && predicate(root)) return root
        for (index in 0 until root.childCount) find(root.getChild(index), predicate)?.let { return it }
        return null
    }

    private fun waitFor(timeout: Long = 10_000, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val deadline = SystemClock.uptimeMillis() + timeout
        do {
            val root = automation.rootInActiveWindow
            root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let { if (predicate(it)) return it }
            find(root, predicate)?.let { return it }
            SystemClock.sleep(5)
        } while (SystemClock.uptimeMillis() < deadline)
        error("The next editable block did not become ready")
    }

    private fun editor(node: AccessibilityNodeInfo) =
        node.viewIdResourceName.orEmpty().startsWith("field.outliner.block.") && node.isFocused

    @Test fun repeatedEnterAtTheStartOfFiveHundredBlocksIsResponsive() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("verifyEnterPerformance") == "true")
        assertTrue("The fixture must never run on a physical device",
            Build.HARDWARE == "ranchu" || Build.MODEL.startsWith("sdk_gphone"))
        val context = instrumentation.targetContext
        assertEquals("uiregression", context.getSharedPreferences("logseq", Context.MODE_PRIVATE)
            .getString("logseq.selectedGraphId", ""))
        val count = arguments.getString("enterFixtureBlocks")?.toInt() ?: 500
        val label = arguments.getString("benchmarkLabel") ?: "before"
        val inputMode = arguments.getString("enterInputMode") ?: "key"
        require(inputMode in listOf("key", "ime"))
        require(label in listOf("before", "after"))
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        context.startActivity(requireNotNull(context.packageManager.getLaunchIntentForPackage(context.packageName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        val first = waitFor(90_000) { it.text?.toString()?.startsWith("Performance row 001-01") == true }
        assertTrue(first.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        waitFor { editor(it) }
        automation.waitForIdle(100, 5_000)
        lateinit var root: ViewRootForTest
        fun findRoot(view: View): ViewRootForTest? {
            if (view is ViewRootForTest) return view
            if (view is ViewGroup) for (index in 0 until view.childCount) {
                findRoot(view.getChildAt(index))?.let { return it }
            }
            return null
        }
        instrumentation.runOnMainSync {
            val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).single()
            root = requireNotNull(findRoot(activity.window.decorView))
        }
        data class Editor(val tag: String, val text: String, val caret: Int, val semanticsId: Int)
        fun focusedEditorNode(node: SemanticsNode): SemanticsNode? {
            val tag = node.config.getOrNull(SemanticsProperties.TestTag).orEmpty()
            if (tag.startsWith("field.outliner.block.") && node.config.getOrNull(SemanticsProperties.Focused) == true) return node
            return node.children.firstNotNullOfOrNull(::focusedEditorNode)
        }
        fun focusedEditor(): Editor? {
            var result: Editor? = null
            instrumentation.runOnMainSync {
                focusedEditorNode(root.semanticsOwner.unmergedRootSemanticsNode)?.let { node ->
                    result = Editor(node.config[SemanticsProperties.TestTag],
                        node.config[SemanticsProperties.EditableText].text,
                        node.config[SemanticsProperties.TextSelectionRange].start, node.id)
                }
            }
            return result
        }
        lateinit var inputConnection: android.view.inputmethod.InputConnection
        instrumentation.runOnMainSync {
            inputConnection = requireNotNull(root.view.onCreateInputConnection(android.view.inputmethod.EditorInfo()))
        }
        fun moveCaret(offset: Int) = instrumentation.runOnMainSync {
            val node = requireNotNull(focusedEditorNode(root.semanticsOwner.unmergedRootSemanticsNode))
            check(requireNotNull(node.config[SemanticsActions.SetSelection].action)(offset, offset, false))
            // Measure splitting a committed block without timing IME candidate confirmation.
            check(inputConnection.finishComposingText())
        }
        fun enter() {
            if (inputMode == "ime") {
                instrumentation.runOnMainSync {
                    check(inputConnection.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_NEXT))
                }
            } else {
                val now = SystemClock.uptimeMillis()
                check(automation.injectInputEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0), false))
                check(automation.injectInputEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0), false))
            }
        }
        fun measureHandoff(previous: Editor, expectedText: String): Pair<Editor, Double> {
            val started = SystemClock.uptimeMillis()
            enter()
            val deadline = started + 10_000
            do {
                val next = focusedEditor()
                if (next != null && next.tag != previous.tag && next.text == expectedText && next.caret == 0) {
                    return next to (SystemClock.uptimeMillis() - started).toDouble()
                }
                SystemClock.sleep(2)
            } while (SystemClock.uptimeMillis() < deadline)
            error("Enter did not focus a new block with <$expectedText>; previous=$previous next=${focusedEditor()}")
        }

        var active = requireNotNull(focusedEditor())
        assertTrue(active.text.startsWith("Performance row 001-01"))
        val samples = mutableListOf<Double>()
        val ids = mutableSetOf(active.tag)
        val nativeEditors = mutableSetOf(active.semanticsId)
        repeat(15) { iteration ->
            // Split a populated block on every sample. Carry the suffix into the next split.
            moveCaret(1)
            active = requireNotNull(focusedEditor())
            assertEquals(1, active.caret)
            assertTrue("Each measured split must leave a nonempty suffix", active.text.length > 1)
            val (next, elapsed) = measureHandoff(active, active.text.drop(1))
            active = next
            assertTrue("Each Enter creates a different block", ids.add(active.tag))
            nativeEditors.add(active.semanticsId)
            if (iteration >= 3) samples.add(elapsed)
        }
        moveCaret(0)
        val (_, insertBeforeMs) = measureHandoff(active, "")
        val database = File(context.filesDir, "graphs/UI_Regression-uiregression/graph.sqlite")
        assertTrue("The offline benchmark graph must exist", database.isFile)
        fun persistedInsertCount(): Int =
            SQLiteDatabase.openDatabase(database.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery(
                    "SELECT COUNT(*) FROM logseq_pending_ops WHERE json_extract(intent, '$.type') IN (?, ?)",
                    arrayOf("insert-block", "split-block"),
                ).use { rows ->
                    check(rows.moveToFirst())
                    rows.getInt(0)
                }
            }
        val insertsBeforeBurst = persistedInsertCount()
        val burstCount = 20
        repeat(burstCount) {
            enter()
            SystemClock.sleep(20)
        }
        val persistenceDeadline = SystemClock.uptimeMillis() + 10_000
        // Keep observing after the expected count so late writes are covered too.
        while (SystemClock.uptimeMillis() < persistenceDeadline) {
            assertTrue("An Enter burst cannot persist extra insertions",
                persistedInsertCount() - insertsBeforeBurst <= burstCount)
            SystemClock.sleep(100)
        }
        assertEquals("Each Enter in the burst must persist exactly one insertion", burstCount,
            persistedInsertCount() - insertsBeforeBurst)
        val settled = focusedEditor() ?: run {
            val screenshot = automation.takeScreenshot()
            File(context.filesDir, "enter-failure.png").outputStream().use {
                screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            val tree = StringBuilder()
            instrumentation.runOnMainSync {
                fun dump(node: SemanticsNode) {
                    tree.append(node.config.toString()).append("\n")
                    node.children.forEach(::dump)
                }
                dump(root.semanticsOwner.unmergedRootSemanticsNode)
                val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).single()
                val runtimeField = MainActivity::class.java.getDeclaredField("runtime").apply { isAccessible = true }
                val runtime = runtimeField.get(activity) as com.logseq.logseq.runtime.LogseqRuntime
                fun dumpRetained(id: Long, depth: Int) {
                    val node = runtime.backend.node(id)
                    val extension = runtime.backend.extensionNode(id)
                    if (node != null) {
                        tree.append("  ".repeat(depth)).append(id).append(": ").append(node.kind)
                            .append(" ").append(node.properties).append(" children=").append(node.children).append("\n")
                        node.children.forEach { dumpRetained(it, depth + 1) }
                    } else if (extension != null) {
                        tree.append("  ".repeat(depth)).append(id).append(": EXT ").append(extension.identifier)
                            .append(" ").append(extension.properties).append("\n")
                        extension.children.forEach { dumpRetained(it, depth + 1) }
                    }
                }
                runtime.rootNodeId?.let { dumpRetained(it, 0) }
            }
            File(context.filesDir, "enter-failure.txt").writeText(tree.toString())
            error("The native editor lost focus during the burst")
        }
        assertEquals("Fast Enter focuses an empty block", "", settled.text)
        assertEquals("Fast Enter preserves the insertion caret", 0, settled.caret)
        val ordered = samples.sorted()
        val median = (ordered[5] + ordered[6]) / 2
        val p95 = ordered.last()
        val report = JSONObject().put("fixture_blocks", count).put("warmup_enters", 3)
            .put("input_mode", inputMode).put("burst_enters", burstCount).put("native_editor_instances", nativeEditors.size)
            .put("insert_before_ms", insertBeforeMs).put("samples_ms", JSONArray(samples)).put("median_ms", median).put("p95_ms", p95)
            .put("measurement", "Enter inside populated text to focused suffix editor in the live Compose semantics tree; no accessibility IPC polling")
            .put("label", label).put("build_revision", BuildConfig.GIT_REVISION)
        File(context.filesDir, "enter-benchmark-$count-$label-$inputMode.json").writeText(report.toString(2))
        println("ENTER_BENCHMARK $report")
        assertEquals("Enter must retain the native editor", 1, nativeEditors.size)
        assertTrue("Enter median should stay below 100ms: $report", median < 100)
        assertTrue("Enter p95 should stay below 150ms: $report", p95 < 150)
    }
}
