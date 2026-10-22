package com.logseq.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidEditorCompletionTest {
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge
    private lateinit var filter: LuiPatchFilter

    @After fun closeBridge() { if (::bridge.isInitialized) ui.runOnIdle { bridge.close() } }

    private fun snapshot(kind: String?, title: String): String = JSONObject().put("ok", true).put("result", JSONObject()
        .put("selectedGraphId", "demo").put("graphName", "Demo")
        .put("outlinerRows", org.json.JSONArray().put(JSONObject().put("depth", 0).put("block", JSONObject()
            .put("uuid", "editing").put("title", title).put("pageId", "page"))))
        .put("outlinerState", JSONObject().put("editing", JSONObject().put("uuid", "editing")
            .put("title", title).put("caretUTF16Offset", title.length))
            .put("selectedBlockIds", org.json.JSONArray()).put("autocomplete", if (kind == null) JSONObject.NULL
                else JSONObject().put("kind", kind).put("query", "")))
        .put("outlinerAutocompleteCandidates", org.json.JSONArray().apply {
            if (kind != null) put(JSONObject().put("label", "Project").put("value", if (kind == "command") "command:embed" else "project").put("group", if (kind == "command") "BASIC" else JSONObject.NULL))
        })).toString()

    private fun start(title: String, kind: String?) {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        filter.applyJson(bridge.applySnapshot(snapshot(kind, title)))
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.darkScheme, typography = LogseqTheme.typography) {
                Surface(Modifier.fillMaxSize(), color = LogseqTheme.darkScheme.background) { backend.Content(root) }
            }
        }
    }

    @Test fun commandsReferencesAndTagsUseOneNativePanel() {
        start("/", "command")
        for ((kind, title) in listOf("command" to "/", "node" to "[[Pro", "tag" to "#Pro")) {
            ui.runOnIdle { bridge.applySnapshot(snapshot(kind, title)).takeIf { it.isNotEmpty() }?.let(filter::applyJson) }
            ui.onNodeWithTag("toolbar.outliner.autocomplete").assertIsDisplayed()
            if (kind == "command") ui.onNodeWithTag("outliner.autocomplete.group.BASIC").assertIsDisplayed()
            ui.onNodeWithTag("button.outliner.autocomplete.dismiss").assertIsDisplayed()
            ui.onNodeWithTag("button.outliner.autocomplete.0").assertIsDisplayed().performClick()
            var chosen: JSONObject? = null
            val observed = mutableListOf<String>()
            try { ui.waitUntil(timeoutMillis = 5000) {
                ui.runOnIdle {
                    repeat(24) {
                        val encoded = bridge.takeEffect()
                        if (encoded.isNotEmpty()) {
                            val effect = JSONObject(encoded).optJSONObject("effect") ?: return@repeat
                            observed.add(effect.toString())
                            if (effect.optString("kind") == "choose-outliner-autocomplete") chosen = effect
                        }
                    }
                }
                chosen != null
            } } catch (error: Throwable) {
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()?.let { bitmap ->
                    val context = InstrumentationRegistry.getInstrumentation().targetContext
                    java.io.File(context.getExternalFilesDir(null), "editor-command.png").outputStream().use {
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                    }
                }
                throw AssertionError("Command $kind did not dispatch; effects: $observed", error)
            }
            assertEquals(if (kind == "command") "command:embed" else "project", chosen?.optString("text"))
            ui.runOnIdle { bridge.resolveEffect(chosen!!.getLong("id"), true, "").takeIf { it.isNotEmpty() }?.let(filter::applyJson) }
        }
    }

    @Test fun nativePasteCarriesItsOriginAcrossTheBridge() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                .setPrimaryClip(ClipData.newPlainText("test", "Pasted text /"))
        }
        start("Keep ", null)
        ui.onNodeWithTag("field.outliner.block.editing").performTouchInput { longClick() }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                android.accessibilityservice.AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        }
        fun pasteAction(node: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
            if (node == null) return null
            if (node.text?.toString().equals("Paste", ignoreCase = true) || node.contentDescription?.toString().equals("Paste", ignoreCase = true)) return node
            for (index in 0 until node.childCount) pasteAction(node.getChild(index))?.let { return it }
            return null
        }
        try {
            ui.waitUntil(timeoutMillis = 5000) { automation.windows.any { pasteAction(it.root) != null } }
        } catch (error: Throwable) {
            automation.takeScreenshot()?.let { bitmap ->
                java.io.File(context.getExternalFilesDir(null), "editor-paste.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
            }
            throw error
        }
        assertTrue(automation.windows.firstNotNullOf { pasteAction(it.root) }.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
        ui.waitUntil(timeoutMillis = 5000) {
            ui.onNodeWithTag("field.outliner.block.editing").fetchSemanticsNode().config
                .getOrElse(androidx.compose.ui.semantics.SemanticsProperties.EditableText) { androidx.compose.ui.text.AnnotatedString("") }
                .text.contains("Pasted text /")
        }
        ui.mainClock.advanceTimeBy(200)
        ui.waitForIdle()
        var pasted = false
        val observed = mutableListOf<String>()
        try { ui.waitUntil(timeoutMillis = 5000) {
            ui.runOnIdle {
                val encoded = bridge.takeEffect()
                if (encoded.isNotEmpty()) {
                    observed.add(encoded)
                    JSONObject(encoded).optJSONObject("effect")?.let { effect ->
                        pasted = effect.optString("kind") == "paste-outliner-text" &&
                            effect.optString("text").contains("Pasted text /")
                    }
                }
            }
            pasted
        } } catch (error: Throwable) { throw AssertionError("Paste effects: $observed", error) }
        assertTrue("A pasted slash must reach the core as a paste: $observed", pasted)
    }
}
