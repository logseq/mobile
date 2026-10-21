package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidMaterialInteractionTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()
    private lateinit var backend: LuiBackend

    private fun op(name: String, vararg values: Pair<String, Any>) = JSONObject()
        .put("op", name).apply { values.forEach { (key, value) -> put(key, value) } }

    private fun render(kind: String, enabled: Boolean = true) {
        backend = LuiBackend(onEvent = { events.add(it) })
        val ops = JSONArray()
            .put(op("create-node", "id" to 1, "kind" to "root"))
            .put(op("create-node", "id" to 2, "kind" to kind))
            .put(op("set-prop", "id" to 2, "property" to "text", "value" to "Choose this"))
            .put(op("set-prop", "id" to 2, "property" to "checked", "value" to false))
            .put(op("set-prop", "id" to 2, "property" to "enabled", "value" to enabled))
        if (kind == "radio") {
            ops.put(op("set-prop", "id" to 2, "property" to "toggle-enabled", "value" to true))
        }
        ops.put(op("insert-child", "parent" to 1, "child" to 2, "index" to 0))
        apply(1, ops)
        content()
    }

    private fun apply(generation: Int, ops: JSONArray) {
        val applied = backend.applyJson(JSONObject().put("generation", generation).put("ops", ops).toString())
        assertTrue(backend.lastError, applied)
    }

    private fun content() {
        ui.setContent {
            MaterialExpressiveTheme {
                Box(Modifier.fillMaxSize()) { backend.Content(1) }
            }
        }
    }

    @Test fun checkboxLabelTogglesExactlyOnce() {
        render("checkbox")
        ui.onNodeWithText("Choose this").performClick()
        ui.runOnIdle { assertEquals(listOf(LuiEvent.ToggleChanged(2, true)), events) }
    }

    @Test fun switchLabelTogglesExactlyOnce() {
        render("switch")
        ui.onNodeWithText("Choose this").performClick()
        ui.runOnIdle { assertEquals(listOf(LuiEvent.ToggleChanged(2, true)), events) }
    }

    @Test fun radioLabelSelectsExactlyOnce() {
        render("radio")
        ui.onNodeWithText("Choose this").performClick()
        ui.runOnIdle { assertEquals(listOf(LuiEvent.ToggleChanged(2, true)), events) }
    }

    @Test fun disabledSelectionLabelsExposeTheirDisabledState() {
        render("checkbox", enabled = false)
        ui.onNodeWithText("Choose this").assertIsNotEnabled()
        ui.runOnIdle { assertTrue(events.isEmpty()) }
    }

    @Test fun tabsExposeSingleSelectionAndFollowModelUpdates() {
        backend = LuiBackend(onEvent = { events.add(it) })
        val ops = JSONArray().put(op("create-node", "id" to 1, "kind" to "root"))
            .put(op("create-node", "id" to 2, "kind" to "tabs"))
            .put(op("insert-child", "parent" to 1, "child" to 2, "index" to 0))
        listOf("First", "Second").forEachIndexed { index, text ->
            val id = index + 3
            ops.put(op("create-node", "id" to id, "kind" to "button"))
                .put(op("set-prop", "id" to id, "property" to "text", "value" to text))
                .put(op("set-prop", "id" to id, "property" to "selected", "value" to (index == 0)))
                .put(op("set-prop", "id" to id, "property" to "press-enabled", "value" to true))
                .put(op("insert-child", "parent" to 2, "child" to id, "index" to index))
        }
        apply(1, ops)
        content()
        ui.onNodeWithText("First").assertIsSelected()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab))
        ui.onNodeWithText("Second").performClick()
        ui.runOnIdle {
            assertEquals(listOf(LuiEvent.Press(4)), events)
            apply(2, JSONArray()
                .put(op("set-prop", "id" to 3, "property" to "selected", "value" to false))
                .put(op("set-prop", "id" to 4, "property" to "selected", "value" to true)))
        }
        ui.onNodeWithText("Second").assertIsSelected()
    }
}
