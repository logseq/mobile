package com.logseq.app

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
import com.logseq.app.ui.extensions.logseqExtensionRegistry
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
                ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            }
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            ui.waitUntil(15_000) {
                var loaded = false
                instrumentation.runOnMainSync { loaded = pdf()?.pdfToViewPoint(PdfPoint(0, 40f, 90f)) != null }
                loaded
            }
            ui.runOnIdle { payload.put("page", 2).put("loading", false); update(payload.toString()) }
            ui.waitUntil(5_000) {
                var restored = false
                instrumentation.runOnMainSync { restored = pdf()?.firstVisiblePage == 1 }
                restored
            }
            instrumentation.runOnMainSync { requireNotNull(pdf()).scrollToPage(0) }
            ui.runOnIdle { payload.put("targetPage", 2).put("navigationToken", 1); update(payload.toString()) }
            ui.waitUntil(5_000) {
                var navigated = false
                instrumentation.runOnMainSync { navigated = pdf()?.firstVisiblePage == 1 }
                navigated
            }
            ui.runOnIdle { payload.put("targetPage", 1).put("navigationToken", 2); update(payload.toString()) }
            ui.waitUntil(5_000) {
                var navigated = false
                instrumentation.runOnMainSync { navigated = pdf()?.firstVisiblePage == 0 }
                navigated
            }
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
                val start = requireNotNull(view.pdfToViewPoint(PdfPoint(0, 42f, 90f)))
                val end = requireNotNull(view.pdfToViewPoint(PdfPoint(0, 230f, 90f)))
                val location = IntArray(2).also(view::getLocationOnScreen)
                points[0] = start.x + location[0]; points[1] = start.y + location[1]
                points[2] = end.x + location[0]; points[3] = end.y + location[1]
            }
            val expectedText = runBlocking {
                nativeDocument.getSelectionBounds(0, android.graphics.PointF(42f, 90f), android.graphics.PointF(230f, 90f))
                    ?.selectedContents?.filterIsInstance<androidx.pdf.content.PdfPageTextContent>()?.joinToString(" ") { it.text }
            }
            assertTrue("The PDF fixture must expose selectable text", !expectedText.isNullOrBlank())
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
            ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            ui.onNodeWithText("Main remains available").assertDoesNotExist()
            instrumentation.runOnMainSync { assertTrue("Full-screen reading must retain the native document", requireNotNull(pdf()).pdfDocument === nativeDocument) }
            ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            ui.onNodeWithTag("pdf.toggle-fullscreen").performClick()
            ui.onNodeWithText("Notes").performClick()
            ui.onNodeWithText("Main remains available").assertIsDisplayed()
            dragWithStylus()
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
            val touchDown = SystemClock.uptimeMillis()
            instrumentation.sendPointerSync(MotionEvent.obtain(touchDown, touchDown, MotionEvent.ACTION_DOWN,
                points[0], points[1], 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN })
            SystemClock.sleep(800)
            instrumentation.sendPointerSync(MotionEvent.obtain(touchDown, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP,
                points[0], points[1], 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN })
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
