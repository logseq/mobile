package com.logseq.app

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.espresso.Espresso.pressBack
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidPageRenameTest {
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge
    private lateinit var filter: LuiPatchFilter

    @After fun closeBridge() { if (::bridge.isInitialized) ui.runOnIdle { bridge.close() } }

    private fun snapshot(title: String, rename: Boolean = true, graph: String = "rename-check"): String {
        val property = JSONObject().put("attr", "block/title").put("title", "Name").put("kind", "string")
            .put("text", title).put("editable", true)
            .put("raw", JSONObject().put("type", "string").put("value", title))
        return JSONObject().put("ok", true).put("result", JSONObject().put("selectedGraphId", graph)
            .put("graphName", graph).put("selectedPage", JSONObject().put("uuid", "page").put("title", title))
            .put("outlinerRows", JSONArray()).put("nodeProperties", JSONObject().put("ownerUuid", "page")
                .put("properties", JSONArray()).put("canDelete", rename).put("rename", if (rename) property else JSONObject.NULL))).toString()
    }

    private fun apply(title: String, rename: Boolean = true, graph: String = "rename-check") {
        bridge.applySnapshot(snapshot(title, rename, graph)).takeIf { it.isNotEmpty() }?.let(filter::applyJson)
    }

    private fun takeRename(): JSONObject {
        var result: JSONObject? = null
        ui.waitUntil(timeoutMillis = 5000) {
            ui.runOnIdle {
                repeat(32) {
                    val raw = bridge.takeEffect()
                    if (raw.isNotEmpty()) JSONObject(raw).optJSONObject("effect")?.let {
                        if (it.optString("kind") == "node-property") result = it
                    }
                }
            }
            result != null
        }
        return requireNotNull(result)
    }

    @Test fun nativeRenameSupportsFailureRetryProtectedPagesAndGraphChanges() {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        apply("Original page")
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Surface(Modifier.fillMaxSize(), color = LogseqTheme.lightScheme.background) { backend.Content(root) }
            }
        }
        val editor = "page.rename.page"
        ui.onNodeWithTag("button.overflow-menu").performClick()
        ui.onNodeWithTag("button.page.rename").assertIsDisplayed().performClick()
        ui.onNodeWithTag("view.edit.clear.$editor").assertDoesNotExist()
        ui.onNodeWithTag("view.edit.value.$editor").assertIsDisplayed().performTextReplacement("Renamed page")
        ui.onNodeWithTag("view.edit.save.$editor").performClick()
        val failed = takeRename()
        val payload = JSONObject(failed.getString("text"))
        assertEquals("rename-check", payload.getString("graphId"))
        assertEquals("page", payload.getString("blockUuid"))
        assertEquals("block/title", payload.getString("attr"))
        assertEquals("Renamed page", payload.getString("value"))
        ui.runOnIdle { bridge.resolveEffect(failed.getLong("id"), false, "Storage unavailable").takeIf { it.isNotEmpty() }?.let(filter::applyJson) }
        ui.onNodeWithTag("view.edit.value.$editor").assertIsDisplayed()
        ui.onNodeWithTag("view.edit.save.$editor").performClick()
        val retried = takeRename()
        ui.runOnIdle {
            apply("Renamed page")
            bridge.resolveEffect(retried.getLong("id"), true, "").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        }
        ui.onNodeWithTag("view.edit.value.$editor").assertDoesNotExist()
        ui.onNodeWithTag("title.selected-page").assertIsDisplayed()
        ui.runOnIdle { apply("Protected page", rename = false) }
        ui.onNodeWithTag("button.overflow-menu").performClick()
        ui.onNodeWithText("Share").assertIsDisplayed()
        ui.onNodeWithTag("button.page.rename").assertDoesNotExist()
        ui.onNodeWithText("Delete").assertDoesNotExist()
        pressBack()
        ui.runOnIdle { apply("Renamed page") }
        ui.onNodeWithTag("button.overflow-menu").performClick()
        ui.onNodeWithTag("button.page.rename").performClick()
        ui.onNodeWithTag("view.edit.value.$editor").assertIsDisplayed()
        ui.runOnIdle { apply("Other graph page", graph = "other-graph") }
        ui.onNodeWithTag("view.edit.value.$editor").assertDoesNotExist()
    }
}
