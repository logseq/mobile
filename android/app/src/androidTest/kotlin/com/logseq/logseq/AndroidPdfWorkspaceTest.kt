package com.logseq.logseq

import android.app.Activity
import android.graphics.Paint
import android.graphics.Bitmap
import android.graphics.pdf.PdfDocument
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.printToString
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.pdf.PdfPoint
import androidx.pdf.view.PdfView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import com.logseq.logseq.ui.extensions.pdfTextSelectionAvailable
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidPdfWorkspaceTest {
    @get:Rule val ui = createComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val commands = mutableListOf<JSONObject>()
    private lateinit var backend: LuiBackend
    private lateinit var payload: JSONObject
    private var generation = 0

    private fun operation(name: String, vararg fields: Pair<String, Any>) = JSONObject().put("op", name)
        .apply { fields.forEach { (key, value) -> put(key, value) } }
    private fun apply(vararg operations: JSONObject) {
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", ++generation)
            .put("ops", JSONArray(operations.toList())).toString()))
    }
    private fun update(value: String) = apply(operation("set-extension-prop", "id" to 2, "property" to "payload", "value" to value))
    private fun findPdf(view: View): PdfView? {
        if (view is PdfView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) findPdf(view.getChildAt(index))?.let { return it }
        return null
    }
    private fun pdf(): PdfView? = ActivityLifecycleMonitorRegistry.getInstance()
        .getActivitiesInStage(Stage.RESUMED).filterIsInstance<Activity>()
        .firstNotNullOfOrNull { findPdf(it.window.decorView) }

    @Test fun nativePdfSelectsWithStylusAndLeavesMainVisible() = runNativePdfScenario(compact = false)
    @Test fun narrowWindowsOpenPdfFullscreenByDefault() = runNativePdfScenario(compact = true)

    private fun runNativePdfScenario(compact: Boolean) {
        val file = File(instrumentation.targetContext.cacheDir, "native-pdf-test.pdf")
        val document = PdfDocument()
        try {
            for (number in 1..2) {
                val page = document.startPage(PdfDocument.PageInfo.Builder(600, if (compact) 2400 else 800, number).create())
                page.canvas.drawText("Android native text selection", 40f, 100f, Paint().apply { textSize = 24f })
                document.finishPage(page)
            }
            file.outputStream().use { document.writeTo(it) }
        } finally { document.close() }
        payload = JSONObject().put("assetUuid", "a9000000-0000-4000-8000-000000000001")
            .put("graphId", "pdf-native-test").put("title", "Research.pdf").put("path", file.path)
            .put("highlights", JSONArray()).put("page", 1).put("loading", true)
        if (!compact) payload.put("fullScreen", false)
        backend = LuiBackend(extensions = logseqExtensionRegistry(), onEvent = { event ->
            if (event is LuiEvent.Extension && event.name == "event") {
                val command = JSONObject(event.values["payload"] as String)
                commands.add(command)
                when (command.optString("action")) {
                    "save" -> {
                        payload.getJSONArray("highlights").put(command.getJSONObject("highlight"))
                        update(payload.toString())
                    }
                    "set-fullscreen" -> { payload.put("fullScreen", command.getBoolean("fullScreen")); update(payload.toString()) }
                    "open-annotations" -> { payload.put("fullScreen", false); update(payload.toString()) }
                    "close" -> update("null")
                }
            }
        })
        apply(operation("create-node", "id" to 1, "kind" to "root"),
            operation("create-extension", "id" to 2, "identifier" to "native-pdf-workspace", "fingerprint" to
                "lui-extension-v1|20:native-pdf-workspace|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:7:payload:string:required:none|events:5:event[7:payload:string:required]"),
            operation("set-extension-prop", "id" to 2, "property" to "payload", "value" to payload.toString()),
            operation("insert-child", "parent" to 1, "child" to 2, "index" to 0),
            operation("create-node", "id" to 3, "kind" to "text"),
            operation("set-prop", "id" to 3, "property" to "text", "value" to "Main remains available"),
            operation("insert-child", "parent" to 2, "child" to 3, "index" to 0))
        ui.setContent { MaterialTheme {
            if (compact) Box(Modifier.width(400.dp).fillMaxHeight()) { backend.Content(1) }
            else backend.Content(1)
        } }
        try {
            if (compact) {
                ui.onNodeWithText("Main remains available").assertDoesNotExist()
            } else {
                ui.onNodeWithText("Main remains available").assertIsDisplayed()
            }
            ui.waitUntil(15_000) {
                var loaded = false
                instrumentation.runOnMainSync { loaded = pdf()?.pdfToViewPoint(PdfPoint(0, 40f, 90f)) != null }
                loaded
            }
            fun waitForPage(pageIndex: Int) {
                ui.waitUntil(10_000) {
                    var onPage = false
                    instrumentation.runOnMainSync { onPage = pdf()?.firstVisiblePage == pageIndex }
                    onPage
                }
            }
            // Exercise navigation in the default full-screen case on every extension level.
            ui.runOnIdle { payload.put("page", if (compact) 2 else 1).put("loading", false); update(payload.toString()) }
            if (compact) {
                waitForPage(1)
                ui.runOnIdle { payload.put("targetPage", 1).put("navigationToken", 1); update(payload.toString()) }
                waitForPage(0)
                ui.runOnIdle { payload.put("targetPage", 2).put("navigationToken", 2); update(payload.toString()) }
                waitForPage(1)
                ui.runOnIdle { payload.put("targetPage", 1).put("navigationToken", 3); update(payload.toString()) }
                waitForPage(0)
                ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            }
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            try {
                ui.waitUntil(15_000) {
                    var loaded = false
                    instrumentation.runOnMainSync { loaded = pdf()?.pdfToViewPoint(PdfPoint(0, 40f, 90f)) != null }
                    loaded && ui.onNodeWithTag("pdf.document").fetchSemanticsNode().config[SemanticsProperties.StateDescription] == "PDF ready"
                }
            } catch (failure: Throwable) { throw AssertionError(ui.onRoot().printToString(), failure) }
            val points = FloatArray(4)
            lateinit var nativeDocument: androidx.pdf.PdfDocument
            instrumentation.runOnMainSync {
                val view = requireNotNull(pdf())
                nativeDocument = requireNotNull(view.pdfDocument)
                view.scrollToPosition(PdfPoint(0, 300f, 90f))
            }
            fun dragWithStylus() {
                instrumentation.runOnMainSync {
                    val view = requireNotNull(pdf())
                    val start = requireNotNull(view.pdfToViewPoint(PdfPoint(0, 42f, 90f)))
                    val end = requireNotNull(view.pdfToViewPoint(PdfPoint(0, 230f, 90f)))
                    assertTrue("The selected passage must remain visible after changing reading mode: point=$start view=${view.width}x${view.height} zoom=${view.zoom} scroll=${view.scrollX},${view.scrollY} page=${view.firstVisiblePage}", start.x in 0f..view.width.toFloat() && start.y in 0f..view.height.toFloat())
                    val location = IntArray(2).also(view::getLocationOnScreen)
                    points[0] = start.x + location[0]; points[1] = start.y + location[1]
                    points[2] = end.x + location[0]; points[3] = end.y + location[1]
                }
                val down = SystemClock.uptimeMillis()
                for (step in 0..8) {
                    val action = when (step) { 0 -> MotionEvent.ACTION_DOWN; 8 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
                    val ratio = step / 8f
                    val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_STYLUS }
                    val coords = MotionEvent.PointerCoords().apply {
                        x = points[0] + (points[2] - points[0]) * ratio
                        y = points[1] + (points[3] - points[1]) * ratio
                        pressure = 1f; size = 0.1f
                    }
                    val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, arrayOf(properties), arrayOf(coords),
                        0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_STYLUS, 0)
                    instrumentation.sendPointerSync(event)
                    event.recycle()
                    SystemClock.sleep(40)
                }
            }
            fun longPressWithFinger() {
                val touchDown = SystemClock.uptimeMillis()
                val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
                val coordinates = MotionEvent.PointerCoords().apply {
                    x = points[0] + (points[2] - points[0]) * 0.15f
                    y = points[1]
                    pressure = 1f
                }
                fun touch(action: Int) = MotionEvent.obtain(touchDown, SystemClock.uptimeMillis(), action, 1,
                    arrayOf(properties), arrayOf(coordinates), 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                val down = touch(MotionEvent.ACTION_DOWN)
                try { instrumentation.sendPointerSync(down) } finally { down.recycle() }
                SystemClock.sleep(800)
                val up = touch(MotionEvent.ACTION_UP)
                try { instrumentation.sendPointerSync(up) } finally { up.recycle() }
            }
            ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            ui.onNodeWithText("Main remains available").assertDoesNotExist()
            instrumentation.runOnMainSync { assertTrue("Full-screen reading must retain the native document", requireNotNull(pdf()).pdfDocument === nativeDocument) }
            ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            ui.onNodeWithText("Notes").performClick()
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            dragWithStylus()
            if (!pdfTextSelectionAvailable()) {
                ui.onNodeWithTag("pdf.document").assertIsDisplayed()
                ui.onNodeWithText("Text highlighting is unavailable on this device", substring = true).assertIsDisplayed()
                ui.onNodeWithTag("pdf.highlight").assertDoesNotExist()
                assertTrue(commands.none { it.optString("action") == "save" })
                return
            }
            val expectedText = runBlocking {
                nativeDocument.getSelectionBounds(0, android.graphics.PointF(42f, 90f), android.graphics.PointF(230f, 90f))
                    ?.selectedContents?.filterIsInstance<androidx.pdf.content.PdfPageTextContent>()?.joinToString(" ") { it.text }
            }
            assertTrue("The PDF fixture must expose selectable text", !expectedText.isNullOrBlank())
            ui.waitUntil(10_000) {
                runCatching { ui.onNodeWithTag("pdf.highlight").assertIsEnabled(); true }.getOrDefault(false)
            }
            ui.onNodeWithTag("pdf.highlight").performClick()
            ui.waitUntil(10_000) { commands.any { it.optString("action") == "save" } }
            val saved = commands.first { it.optString("action") == "save" }
            assertEquals("pdf-native-test", saved.getString("graphId"))
            val highlight = saved.getJSONObject("highlight")
            assertEquals("Stylus coordinates must select the same text as the native PDF document", expectedText,
                highlight.getJSONObject("content").getString("text"))
            assertEquals(1, highlight.getInt("page"))
            assertTrue(highlight.getJSONObject("position").getJSONArray("rects").length() > 0)
            ui.onNodeWithText("Copy reference").performScrollTo().performClick()
            ui.waitUntil(5_000) {
                var copied = false
                instrumentation.runOnMainSync {
                    val clipboard = instrumentation.targetContext.getSystemService(android.content.ClipboardManager::class.java)
                    copied = clipboard.primaryClip?.getItemAt(0)?.text?.toString() == "[[${highlight.getString("id")}]]"
                }
                copied
            }
            ui.onNodeWithText("Reference copied").assertIsDisplayed()
            ui.onNodeWithTag("pdf.highlight").performScrollTo()
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            instrumentation.uiAutomation.takeScreenshot().let { screenshot ->
                File(instrumentation.targetContext.cacheDir, "pdf-workspace.png").outputStream().use {
                    screenshot.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                screenshot.recycle()
            }
            dragWithStylus()
            ui.waitUntil(10_000) {
                runCatching { ui.onNodeWithTag("pdf.highlight").assertIsEnabled(); true }.getOrDefault(false)
            }
            longPressWithFinger()
            ui.waitUntil(5_000) {
                var selected = false
                instrumentation.runOnMainSync { selected = pdf()?.currentSelection is androidx.pdf.selection.model.TextSelection }
                selected
            }
            ui.onNodeWithText("Copy reference").assertIsNotEnabled()
            lateinit var fingerText: String
            instrumentation.runOnMainSync {
                fingerText = (requireNotNull(pdf()).currentSelection as androidx.pdf.selection.model.TextSelection).text.toString()
            }
            ui.onNodeWithTag("pdf.highlight").performClick()
            ui.waitUntil(10_000) { commands.count { it.optString("action") == "save" } == 2 }
            assertEquals("Finger selection must replace an unsaved stylus selection", fingerText,
                commands.last { it.optString("action") == "save" }.getJSONObject("highlight").getJSONObject("content").getString("text"))
            ui.onNodeWithTag("pdf.close").performClick()
            ui.waitUntil(10_000) {
                var closed = false
                instrumentation.runOnMainSync { closed = pdf() == null }
                closed
            }
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
        } finally { file.delete() }
    }
}
