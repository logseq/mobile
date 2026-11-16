package com.logseq.logseq

import android.graphics.Bitmap
import android.os.Bundle
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.logseq.runtime.*
import com.logseq.logseq.ui.LogseqTheme
import com.logseq.logseq.ui.logseqContentHostInsets
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Identical offline inputs for baseline/fixed screenshot comparisons. */
class AndroidDarkThemeScreenshotTest {
    @get:Rule val ui = createComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val args get() = InstrumentationRegistry.getArguments()
    private var bridge: LogseqNativeBridge? = null

    private fun mount(projection: JSONObject) {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        val filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        native.applyHostUpdate("settings", """{"appearance":"dark","language":"system","systemLanguage":"en-US","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"http://127.0.0.1:1","version":"QA","revision":"dark-theme"}""")
            .takeIf(String::isNotEmpty)?.let(filter::applyJson)
        val result = JSONObject().put("selectedGraphId", "dark-theme").put("graphName", "Theme audit")
            .put("isGraphUnlocked", true).put("syncConnected", false)
            .put("outlinerRows", JSONArray())
        projection.keys().forEach { result.put(it, projection.get(it)) }
        filter.applyJson(native.applySnapshot(JSONObject().put("ok", true).put("result", result).toString()))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.darkScheme, typography = LogseqTheme.typography) {
                CompositionLocalProvider(dev.lui.LocalLuiThemeDark provides true,
                    dev.lui.LocalLuiSemanticColors provides LogseqTheme.semanticColors(LogseqTheme.darkScheme)) {
                    Surface(color = LogseqTheme.darkScheme.background) {
                        Box(Modifier.fillMaxSize().logseqContentHostInsets()) { backend.Content(root) }
                    }
                }
            }
        }
    }

    private fun row(id: String, title: String, markup: JSONArray? = null, status: String? = null): JSONObject {
        val block = JSONObject().put("uuid", id).put("title", title).put("pageId", "theme-page")
        markup?.let { block.put("markup", it) }
        status?.let { block.put("status", JSONObject().put("uuid", "status-$it").put("title", it)
            .put("ident", "logseq.property.task.status/$it")) }
        return JSONObject().put("depth", 0).put("block", block)
    }

    private fun capture(name: String) {
        ui.waitForIdle()
        Thread.sleep(1200)
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(instrumentation.targetContext.getExternalFilesDir(null), "dark-theme-$name.png")
            .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @After fun close() { bridge?.let { ui.runOnIdle { it.close() } } }

    @Test fun captureThemeRegression() {
        val scenario = args.getString("themeScenario") ?: "html"
        when (scenario) {
            "prepare-dark", "prepare-light", "prepare-system" -> {
                AndroidPlatformServices(instrumentation.targetContext).saveSettings(
                    JSONObject().put("appearance", scenario.substringAfterLast('-')).toString())
                // SharedPreferences.apply publishes in memory synchronously;
                // commit the same value before an external cold-start capture.
                instrumentation.targetContext.getSharedPreferences("logseq", android.content.Context.MODE_PRIVATE)
                    .edit().putString("logseq.appearance", scenario.substringAfterLast('-')).commit()
            }
            "html" -> {
                val html = JSONArray().put(JSONObject().put("type", "html").put("text",
                    "<p>Default HTML text</p><a href='https://example.com'>HTML link</a><input value='HTML input'>"))
                mount(JSONObject().put("outlinerRows", JSONArray().put(row("html", "HTML block", html))))
                ui.onNodeWithTag("block.rich.html").assertExists()
                capture(scenario)
            }
            "flashcards" -> {
                val card = JSONObject().put("block", JSONObject().put("uuid", "card").put("title", "Can you read this button?"))
                    .put("children", JSONArray().put(JSONObject().put("uuid", "answer").put("title", "Answer: preserve contrast")))
                mount(JSONObject().put("flashcards", JSONArray().put(card))
                    .put("flashcardDecks", JSONObject().put("totalCards", 1).put("completed", false)))
                ui.onNodeWithTag("button.sidebar").performClick()
                ui.onNodeWithTag("link.sidebar.flashcards").performClick()
                ui.onNodeWithTag("button.flashcard.show-answer").assertIsDisplayed()
                capture(scenario)
            }
            "task-statuses" -> {
                val rows = JSONArray()
                listOf("backlog", "todo", "doing", "in-review", "done", "canceled").forEach {
                    rows.put(row("task-$it", "${it.replaceFirstChar(Char::uppercase)} task", status = it))
                }
                mount(JSONObject().put("selectedPage", JSONObject().put("uuid", "theme-page").put("title", "Task status contrast"))
                    .put("outlinerRows", rows))
                ui.onNodeWithText("Backlog task").assertIsDisplayed()
                capture(scenario)
            }
            else -> error("Unknown dark-theme scenario: $scenario")
        }
        instrumentation.sendStatus(2, Bundle().apply { putString("theme-capture-complete", scenario) })
    }
}
