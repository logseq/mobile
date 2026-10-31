package com.logseq.app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import android.os.Bundle
import org.junit.runners.Parameterized
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.*
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Real core and renderer scenarios, with deterministic offline graph and camera input. */
@RunWith(Parameterized::class)
class AndroidFeedbackRecordingTest(private val scenario: String) {
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun scenarios(): List<Array<String>> {
            val args = InstrumentationRegistry.getArguments()
            return (args.getString("feedbackScenarios") ?: args.getString("feedbackScenario") ?: "navigation")
                .split(',').map { arrayOf(it) }
        }
    }
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge
    private lateinit var filter: LuiPatchFilter
    private lateinit var loader: AndroidGraphAssetLoader
    private var selectedSnapshot = ""
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val args get() = InstrumentationRegistry.getArguments()
    private val verify get() = args.getString("feedbackPhase") != "before"
    private val context get() = instrumentation.targetContext
    private lateinit var graph: File
    private var step = 0
    private fun uuid(n: Int) = "f0000000-0000-4000-8000-" + n.toString().padStart(12, '0')
    private fun request(action: String?, payload: String? = null, path: String? = null): String = runBlocking {
        bridge.callCore(JSONObject().put("apiVersion", 1).put("method", if (action == null) "open" else "dispatch")
            .put("params", JSONObject().apply { action?.let { put("action", it) }; payload?.let { put("payload", it) }; path?.let { put("path", it) } }).toString())
    }
    private fun apply(response: String) = ui.runOnIdle {
        bridge.applySnapshot(response).takeIf { it.isNotEmpty() }?.let(filter::applyJson)
    }
    private fun host(kind: String, payload: String) = ui.runOnIdle {
        bridge.applyHostUpdate(kind, payload).takeIf { it.isNotEmpty() }?.let(filter::applyJson)
    }
    private fun drain() {
        repeat(80) {
            var raw = ""
            ui.runOnIdle { raw = bridge.takeEffect() }
            val envelope = runCatching { JSONObject(raw) }.getOrNull() ?: return
            val effect = envelope.optJSONObject("effect") ?: return
            envelope.optString("patch").takeIf { it.isNotEmpty() }?.let { patch -> ui.runOnIdle { filter.applyJson(patch) } }
            val kind = effect.optString("kind")
            var message = ""
            if (kind !in setOf("refresh-graphs", "persist-ui-session", "persist-composer-draft", "save-settings", "present-attachment")) {
                val response = request("executeEffect", effect.toString())
                if (kind == "maintain-search-index") message = response else apply(response)
            }
            ui.runOnIdle { bridge.resolveEffect(effect.getLong("id"), true, message).takeIf { it.isNotEmpty() }?.let(filter::applyJson) }
        }
        error("The native effect queue did not drain")
    }
    private fun pause() {
        drain(); ui.waitForIdle(); Thread.sleep(1800)
        step++
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            File(context.getExternalFilesDir(null), "feedback-$scenario-$step.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }; bitmap.recycle()
        }
    }
    private fun mount(page: Int) {
        val directory = File(context.cacheDir, "feedback-recording").apply { deleteRecursively(); mkdirs() }
        graph = File(directory, "graphs/feedback").apply { mkdirs() }
        for (name in listOf("graph.sqlite", "sync.checkpoint")) {
            instrumentation.context.assets.open("feedback/$name").use { input -> File(graph, name).outputStream().use(input::copyTo) }
        }
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) }, extensions = logseqExtensionRegistry(
            loadImage = { uuid, type -> loader.load(uuid, type) },
            resolveAssetPath = { path -> if (path.isEmpty() || File(path).isAbsolute) path else File(graph, path).path }), icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        loader = AndroidGraphAssetLoader(File(context.cacheDir, "feedback-downloads"), bridge::callCore)
        request(null, path = File(directory, "logseq.sqlite").path)
        request("configure", """{"graphId":"feedback","baseUrl":"http://127.0.0.1:1","token":""}""")
        val opened = request("openGraph", JSONObject().put("graphId", "feedback").put("activePath", File(graph, "graph.sqlite").path)
            .put("checkpointPath", File(graph, "sync.checkpoint").path).put("isEncrypted", false).toString())
        check(JSONObject(opened).optBoolean("ok")) { opened }
        val selected = request("selectPage", uuid(page))
        selectedSnapshot = selected
        val root = bridge.initialize(authenticationCode = 3)
        apply(opened); apply(selected)
        host("local-graph-ids", """["feedback"]""")
        host("graph-loading", "false")
        ui.setContent { MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
            Box(Modifier.fillMaxSize()) { backend.Content(root) }
        } }
        pause()
    }
    @After fun close() { if (::bridge.isInitialized) ui.runOnIdle { bridge.close() } }
    @Test fun recordFeedbackScenario() {
        instrumentation.sendStatus(2, Bundle().apply { putString("feedback-start", scenario) })
        var succeeded = false
        try {
            recordCase()
            succeeded = true
        } finally {
            instrumentation.sendStatus(2, Bundle().apply {
                putString("feedback-end", scenario)
                putString("feedback-success", succeeded.toString())
            })
        }
    }
    private fun recordCase() {
        when (scenario) {
            "responsiveness" -> {
                mount(1)
                request("configure", JSONObject().put("graphId", "").put("baseUrl", args.getString("feedbackCatalogUrl"))
                    .put("token", "feedback-test-token").toString())
                var workerError: Throwable? = null
                val worker = kotlin.concurrent.thread {
                    try {
                        if (verify) runBlocking { GraphCatalogClient(bridge::callCore).refresh() }
                        else request("refreshGraphCatalog")
                    } catch (error: Throwable) { workerError = error }
                }
                Thread.sleep(300)
                val started = android.os.SystemClock.elapsedRealtime()
                ui.onNodeWithTag("button.sidebar").performClick()
                drain()
                ui.waitUntil(10000) { drain(); runCatching { ui.onNodeWithTag("button.sidebar.settings").assertIsDisplayed() }.isSuccess }
                ui.onNodeWithTag("button.sidebar.settings").performClick()
                drain()
                ui.waitUntil(10000) { drain(); runCatching { ui.onNodeWithTag("button.connection.apply").assertIsDisplayed() }.isSuccess }
                val elapsed = android.os.SystemClock.elapsedRealtime() - started
                val requestStillPending = worker.isAlive
                println("SETTINGS_OPEN_MS=$elapsed")
                instrumentation.sendStatus(2, Bundle().apply {
                    putString("settings-open-ms", elapsed.toString())
                    putString("request-pending-when-settings-open", requestStillPending.toString())
                })
                pause(); worker.join(10000)
                workerError?.let { throw AssertionError("Catalog refresh failed", it) }
                if (verify) assertTrue("Settings must open before the delayed HTTP request completes ($elapsed ms)", requestStillPending)
            }
            "navigation" -> {
                mount(1); host("open-node", JSONObject.quote(uuid(1))); pause()
                ui.onAllNodesWithTag("outliner-block-content-" + uuid(21)).onLast().performTouchInput { click(Offset(20f, center.y)) }; pause()
                if (verify) {
                    val titleBounds = ui.onAllNodesWithTag("title.node").onLast().getUnclippedBoundsInRoot()
                    assertTrue("Hidden pages must not leave a blank area above the current page", titleBounds.top < 160.dp)
                    val oldRows = ui.onAllNodesWithText("Journal content")
                    oldRows.fetchSemanticsNodes().indices.forEach { oldRows[it].assertIsNotDisplayed() }
                }
                ui.onAllNodesWithTag("button.navigation.back").onLast().performClick(); pause()
                if (verify) {
                    val journalRows = ui.onAllNodesWithText("Journal content")
                    assertTrue("Returning reveals the journal page", journalRows.fetchSemanticsNodes().indices.any {
                        runCatching { journalRows[it].assertIsDisplayed() }.isSuccess
                    })
                }
            }
            "attachment-refresh", "image-parent", "image-retry" -> {
                mount(3)
                ui.onNodeWithTag("outliner-block-content-" + uuid(13)).performClick(); pause()
                val attachmentButton = ui.onNodeWithTag(if (scenario == "image-parent") "button.outliner.editor.attachment" else "button.outliner.editor.camera")
                attachmentButton.performScrollTo().performClick(); pause()
                val file = File(context.cacheDir, "captured.png")
                val bitmap = Bitmap.createBitmap(640, 360, Bitmap.Config.ARGB_8888)
                Canvas(bitmap).apply { drawColor(android.graphics.Color.rgb(40, 130, 100)); drawText("Captured photo", 55f, 190f,
                    Paint().apply { color = android.graphics.Color.WHITE; textSize = 55f }) }
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
                val response = request("addAsset", JSONObject().put("uuid", uuid(30)).put("title", "Captured photo.png").put("assetType", "png")
                    .put("assetSize", file.length()).put("assetChecksum", "feedback-photo").put("localPath", file.path).put("targetBlockId", uuid(13)).toString())
                apply(response); pause()
                if (verify) {
                    assertTrue(response, JSONObject(response).optBoolean("ok"))
                    ui.onNodeWithTag("field.outliner.block." + uuid(13)).assertDoesNotExist()
                    ui.onNodeWithTag("asset.preview.image").assertIsDisplayed()
                    val rows = JSONObject(response).getJSONObject("result").getJSONArray("outlinerRows")
                    assertEquals("An empty image target is replaced, without a blank parent", 1, rows.length())
                    val block = rows.getJSONObject(0).getJSONObject("block")
                    assertTrue(block.getBoolean("isAsset"))
                    assertTrue("Offline preview uses the imported local file", File(block.getString("localPath")).isFile)
                    val preview = JSONObject(request("prepareAssetDownload", JSONObject().put("uuid", block.getString("uuid")).put("assetType", "png").toString())).getJSONObject("result")
                    assertEquals(block.getString("localPath"), preview.getString("localPath"))
                    assertFalse("A local import must not request a remote download", preview.has("request"))
                }
            }
            "special-block", "android-controls" -> {
                mount(2); ui.onNodeWithText("print(42)").performTouchInput { click() }; pause()
                if (verify) ui.onNodeWithTag("button.outliner.placeholder." + uuid(2)).assertIsDisplayed()
            }
            "code-language" -> {
                mount(2)
                if (verify) {
                    ui.onNodeWithTag("button.outliner.code-language." + uuid(12)).performClick(); pause()
                    ui.onNodeWithTag("button.outliner.code-language.option.python").performClick(); pause()
                }
            }
            "calculator-live", "calculator-toolbar" -> {
                mount(2)
                val configured = request("nodeProperty", JSONObject().put("action", "setCodeLanguage")
                    .put("blockUuid", uuid(12)).put("value", "calc").toString())
                assertTrue(configured, JSONObject(configured).optBoolean("ok"))
                apply(configured)
                pause()
                val content = ui.onNodeWithTag("outliner.code.content." + uuid(12), useUnmergedTree = true)
                content.assertExists(ui.onRoot(useUnmergedTree = true).printToString())
                content.assertIsDisplayed().performClick()
                pause()
                val editor = ui.onNodeWithTag("field.outliner.block." + uuid(12), useUnmergedTree = true)
                editor.assertExists(ui.onRoot(useUnmergedTree = true).printToString())
                val results = ui.onNodeWithTag("outliner.calculator.results." + uuid(12), useUnmergedTree = true)
                editor.performTextReplacement("6*7\nlast*3")
                ui.waitUntil(10_000) {
                    drain()
                    runCatching { results.assertTextEquals("42\n126") }.isSuccess
                }
                val inputBounds = editor.getUnclippedBoundsInRoot()
                val outputBounds = results.getUnclippedBoundsInRoot()
                assertTrue("Calculator results occupy the right column", outputBounds.left >= inputBounds.right)
                editor.performKeyInput { pressKey(Key.Enter) }
                editor.assertTextEquals("6*7\nlast*3\n")
                drain()
                val beforeCount = JSONObject(configured).getJSONObject("result").getJSONArray("outlinerRows").length()
                assertEquals("Enter stays inside Calculator", beforeCount,
                    JSONObject(request("refresh")).getJSONObject("result").getJSONArray("outlinerRows").length())
                if (scenario == "calculator-toolbar") {
                    ui.mainClock.autoAdvance = false
                    try {
                        editor.performTextInput("pending🙂")
                        ui.onNodeWithTag("button.outliner.editor.newBlock").performClick()
                        drain()
                    } finally {
                        ui.mainClock.autoAdvance = true
                    }
                } else {
                    editor.performKeyInput { keyDown(Key.ShiftLeft); pressKey(Key.Enter); keyUp(Key.ShiftLeft) }
                }
                ui.waitUntil(10_000) {
                    drain()
                    runCatching { editor.assertDoesNotExist() }.isSuccess
                }
                val after = JSONObject(request("refresh")).getJSONObject("result").getJSONArray("outlinerRows")
                assertEquals("Shift+Enter creates exactly one new block", beforeCount + 1, after.length())
                if (scenario == "calculator-toolbar") {
                    val source = (0 until after.length()).map { after.getJSONObject(it).getJSONObject("block") }
                        .single { it.getString("uuid") == uuid(12) }
                    assertEquals("The toolbar preserves typing that has not reached the debounced core update",
                        "6*7\nlast*3\npending🙂", source.getString("title"))
                }
                content.performTouchInput { longClick() }
                ui.waitUntil(10_000) {
                    drain()
                    runCatching { ui.onNodeWithTag("button.outliner.selection.copy").assertIsDisplayed() }.isSuccess
                }
                pause()
            }
            "natural-date" -> {
                mount(1)
                fun event(type: String, fields: JSONObject = JSONObject()): JSONObject {
                    val response = request("outlinerEvent", fields.put("type", type).toString())
                    assertTrue(response, JSONObject(response).optBoolean("ok"))
                    return JSONObject(response).getJSONObject("result")
                }
                fun command(label: String) {
                    event("tapBlock", JSONObject().put("uuid", uuid(11)))
                    val result = event("textChanged", JSONObject().put("title", "/").put("caretUTF16Offset", 1))
                    val options = result.getJSONArray("outlinerAutocompleteCandidates")
                    val option = (0 until options.length()).map(options::getJSONObject).single { it.getString("label") == label }
                    event("chooseAutocomplete", JSONObject().put("value", option.getString("value")))
                }
                command("Date picker")
                event("submitAutocomplete", JSONObject().put("value", "January 1, 2000"))
                event("saveEditing")
                drain()
                val saved = request("refresh")
                assertTrue("The native date command creates a Journal reference", saved.contains("00000001-2000-0101-0000-000000000000"))
                command("Scheduled")
                event("submitAutocomplete", JSONObject().put("value", "January 1, 2000 at 3pm"))
                event("saveEditing")
                val properties = JSONObject(request("nodeProperties", uuid(11))).getJSONObject("result").getJSONObject("nodeProperties").getJSONArray("properties")
                val scheduled = (0 until properties.length()).map(properties::getJSONObject)
                    .single { it.getString("attr") == "logseq.property/scheduled" }
                val expected = java.util.GregorianCalendar(2000, 0, 1, 15, 0, 0).apply {
                    set(java.util.Calendar.MILLISECOND, 0)
                }.timeInMillis
                assertEquals("NLP date-time input uses the device's local time", expected.toString(), scheduled.getString("editorValue"))
            }
            "language" -> {
                mount(1); host("settings", """{"appearance":"system","language":"system","systemLanguage":"zh-CN","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"http://127.0.0.1:1","version":"QA","revision":"feedback"}""")
                ui.onNodeWithTag("button.sidebar").performClick(); pause()
                ui.onNodeWithTag("button.sidebar.settings").performClick(); pause()
                if (verify) ui.onNodeWithText("设置").assertExists()
            }
            "comments", "reactions" -> {
                mount(7); pause()
                if (verify) {
                    if (scenario == "comments") ui.onNodeWithTag("outliner.comment." + uuid(19)).assertExists()
                    else ui.onNodeWithText("👍 1").assertIsDisplayed()
                }
            }
            "youtube" -> {
                mount(4); pause()
                if (verify) assertEquals("video", JSONObject(selectedSnapshot).getJSONObject("result").getJSONArray("outlinerRows")
                    .getJSONObject(0).getJSONObject("block").getJSONArray("markup").getJSONObject(0).getString("type"))
            }
            "math" -> {
                mount(5); pause()
                if (verify) ui.onNodeWithText("For each mouse", substring = true)
                    .assertTextContains("be heteroplasmy in tissue t at culling.", substring = true)
            }
            "search-tags" -> {
                mount(1); ui.onNodeWithTag("button.search").performClick(); pause()
                ui.onNodeWithTag("field.search").performTextInput("#code"); pause()
                if (verify) ui.onNodeWithText("Code", ignoreCase = true).assertExists()
            }
            "search-toolbar" -> {
                mount(1); ui.onNodeWithTag("button.search").performClick(); pause()
                ui.onNodeWithTag("field.search").performTextInput("print"); pause()
                ui.onNodeWithTag("search.result." + uuid(12)).performClick(); pause()
                ui.onNodeWithTag("outliner-block-content-" + uuid(12)).performClick(); pause()
                if (verify) {
                    ui.onNodeWithTag("field.search").assertDoesNotExist()
                    ui.onNodeWithTag("toolbar.outliner.editor").assertIsDisplayed()
                }
            }
            else -> error("Unknown feedback scenario: $scenario")
        }
    }
}
