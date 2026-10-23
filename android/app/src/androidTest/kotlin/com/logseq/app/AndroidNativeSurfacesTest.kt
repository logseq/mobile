package com.logseq.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.logseqIconResolver
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
class AndroidNativeSurfacesTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()
    private lateinit var backend: LuiBackend
    private var generation = 0

    private fun op(name: String, vararg values: Pair<String, Any>) = JSONObject()
        .put("op", name).apply { values.forEach { (key, value) -> put(key, value) } }

    private fun apply(ops: JSONArray) {
        val applied = backend.applyJson(JSONObject().put("generation", ++generation).put("ops", ops).toString())
        assertTrue(backend.lastError, applied)
    }

    private fun render(kind: String, props: Map<String, Any> = emptyMap(), drawer: Boolean = false) {
        backend = LuiBackend(onEvent = { events.add(it) }, icons = logseqIconResolver)
        val ops = JSONArray().put(op("create-node", "id" to 1, "kind" to "root"))
            .put(op("create-node", "id" to 2, "kind" to kind))
            .put(op("insert-child", "parent" to 1, "child" to 2, "index" to 0))
        props.forEach { (name, value) ->
            ops.put(op("set-prop", "id" to 2, "property" to name, "value" to value))
        }
        if (drawer || kind == "popover") {
            listOf("Main content", "Panel content").forEachIndexed { index, text ->
                if (drawer || index == 1) {
                    val id = index + 3
                    ops.put(op("create-node", "id" to id, "kind" to "text"))
                        .put(op("set-prop", "id" to id, "property" to "text", "value" to text))
                        .put(op("insert-child", "parent" to 2, "child" to id, "index" to if (drawer) index else 0))
                }
            }
        }
        apply(ops)
        ui.setContent {
            MaterialExpressiveTheme {
                Box(Modifier.fillMaxSize().background(Color.White)) { backend.Content(1) }
            }
        }
    }

    private fun setSelected(selected: Boolean) = ui.runOnIdle {
        apply(JSONArray().put(op("set-prop", "id" to 2, "property" to "selected", "value" to selected)))
    }

    @Test fun drawerOpensAndClosesWithNativeMotionInsteadOfReplacingThePanel() {
        render("drawer", mapOf("selected" to false, "toggle-enabled" to true), drawer = true)
        ui.mainClock.autoAdvance = false
        setSelected(true)
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithText("Panel content").assertIsNotDisplayed()
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Panel content").assertIsDisplayed()
        setSelected(false)
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithText("Panel content").assertExists()
        ui.mainClock.advanceTimeBy(1_000)
        ui.onNodeWithText("Panel content").assertIsNotDisplayed()
        ui.mainClock.autoAdvance = true
        ui.runOnIdle { assertTrue(events.isEmpty()) }
    }

    @Test fun drawerHasNativeDismissAccessibilityAndEmitsOneCloseEvent() {
        render("drawer", mapOf("selected" to true, "toggle-enabled" to true), drawer = true)
        ui.onNode(SemanticsMatcher.keyIsDefined(SemanticsActions.Dismiss))
            .performSemanticsAction(SemanticsActions.Dismiss) { it() }
        ui.onNodeWithText("Panel content").assertIsNotDisplayed()
        ui.runOnIdle { assertEquals(listOf(LuiEvent.ToggleChanged(2, false)), events) }
    }

    @Test fun disabledDrawerDoesNotOpenFromASwipe() {
        render("drawer", mapOf("selected" to false, "enabled" to false, "toggle-enabled" to true), drawer = true)
        ui.onRoot().performTouchInput { swipeRight() }
        ui.onNodeWithText("Panel content").assertIsNotDisplayed()
        ui.runOnIdle { assertTrue(events.isEmpty()) }
    }

    @Test fun drawerScrimClosesLocallyWithoutWaitingForAModelEcho() {
        render("drawer", mapOf("selected" to true, "toggle-enabled" to true, "width" to 240), drawer = true)
        ui.onRoot().performTouchInput { click(Offset(width - 8f, center.y)) }
        ui.onNodeWithText("Panel content").assertIsNotDisplayed()
        ui.runOnIdle { assertEquals(listOf(LuiEvent.ToggleChanged(2, false)), events) }
    }

    @Test fun popoverUsesANativePopupWindowAndBackDismissesIt() {
        render("popover", mapOf("anchor" to "below"))
        ui.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.IsPopup)).assertExists()
        ui.onNodeWithText("Panel content").assertIsDisplayed()
        ui.runOnIdle {
            val popup = android.view.inspector.WindowInspector.getGlobalWindowViews().last()
            popup.dispatchKeyEvent(android.view.KeyEvent(0, android.view.KeyEvent.KEYCODE_BACK))
            popup.dispatchKeyEvent(android.view.KeyEvent(1, android.view.KeyEvent.KEYCODE_BACK))
        }
        ui.runOnIdle { assertEquals(listOf(LuiEvent.Dismiss(2)), events) }
    }

    private fun assertModalControlsExposeResourceIds(kind: String) {
        render(kind)
        ui.runOnIdle {
            val ops = JSONArray()
            listOf("text-field", "switch", "button").forEachIndexed { index, control ->
                val id = index + 3
                ops.put(op("create-node", "id" to id, "kind" to control))
                    .put(op("set-prop", "id" to id, "property" to "accessibility-identifier", "value" to "modal.$control"))
                    .put(op("set-prop", "id" to id, "property" to "text", "value" to control))
                    .put(op("insert-child", "parent" to 2, "child" to id, "index" to index))
            }
            apply(ops)
        }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val originalInfo = automation.serviceInfo
        automation.serviceInfo = android.accessibilityservice.AccessibilityServiceInfo().apply {
            eventTypes = originalInfo.eventTypes
            feedbackType = originalInfo.feedbackType
            flags = originalInfo.flags or
                android.accessibilityservice.AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        fun resourceIds(): Set<String> {
            val pending = java.util.ArrayDeque<android.view.accessibility.AccessibilityNodeInfo>()
            automation.windows.forEach { window -> window.root?.let { pending.add(it) } }
            val ids = mutableSetOf<String>()
            while (pending.isNotEmpty()) {
                val node = pending.removeFirst()
                node.viewIdResourceName?.let { ids.add(it) }
                repeat(node.childCount) { index -> node.getChild(index)?.let { pending.add(it) } }
            }
            return ids
        }
        val expected = setOf("modal.text-field", "modal.switch", "modal.button")
        try {
            ui.waitUntil(5_000) { resourceIds().containsAll(expected) }
        } finally {
            automation.serviceInfo = originalInfo
        }
    }

    @Test fun dialogControlsExposeResourceIdsInTheirOwnNativeWindow() {
        assertModalControlsExposeResourceIds("dialog")
    }

    @Test fun sheetControlsExposeResourceIdsInTheirOwnNativeWindow() {
        assertModalControlsExposeResourceIds("sheet")
    }

    @Test fun selectedListItemsExposeNativeSingleSelection() {
        render("list-item", mapOf("text" to "Example", "selected" to true, "press-enabled" to true))
        ui.onNodeWithText("Example").assertIsSelected().performClick()
        ui.runOnIdle { assertEquals(listOf(LuiEvent.Press(2)), events) }
    }

    @Test fun disabledListLabelsExposeTheNativeDisabledState() {
        render("list-item", mapOf("text" to "Example", "enabled" to false, "press-enabled" to true))
        ui.onNodeWithText("Example").assertIsNotEnabled()
        ui.runOnIdle { assertTrue(events.isEmpty()) }
    }

    @Test fun primaryIconButtonUsesTheNativeIconContainerSize() {
        render("button", mapOf("icon" to "app:composer-add", "variant" to "primary", "accessibility-label" to "Example"))
        ui.onNodeWithContentDescription("Example").assertWidthIsEqualTo(40.dp)
    }

    @Test fun buttonPressMorphsTheNativeShape() {
        render("button", mapOf("text" to "Example", "variant" to "primary", "press-enabled" to true))
        val button = ui.onNodeWithText("Example")
        fun cornerCoverage(): Int {
            val pixels = button.captureToImage().toPixelMap()
            var count = 0
            for (x in 0 until pixels.width / 5) for (y in 0 until pixels.height / 3) {
                val color = pixels[x, y]
                if (color.red < .85f || color.green < .85f || color.blue < .85f) count++
            }
            return count
        }
        val resting = cornerCoverage()
        ui.mainClock.autoAdvance = false
        button.performTouchInput { down(center) }
        ui.mainClock.advanceTimeBy(500)
        val pressed = cornerCoverage()
        button.performTouchInput { up() }
        ui.mainClock.autoAdvance = true
        assertTrue("The pressed container must morph beyond its resting capsule: $resting -> $pressed", pressed > resting + 25)
        ui.runOnIdle { assertEquals(listOf(LuiEvent.Press(2)), events) }
    }
}
