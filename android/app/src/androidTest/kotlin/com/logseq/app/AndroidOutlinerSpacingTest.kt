package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTouchHeightIsEqualTo
import androidx.compose.ui.test.assertTouchWidthIsEqualTo
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidOutlinerSpacingTest {
    @get:Rule val ui = createComposeRule()
    private var bridge: LogseqNativeBridge? = null
    private lateinit var filter: LuiPatchFilter
    private val events = mutableListOf<LuiEvent>()
    private val journal = "Oct 22nd, 2026"

    @After fun closeBridge() { bridge?.let { ui.runOnIdle { it.close() } } }

    private fun snapshot(editing: Boolean = false, priority: Boolean = false, status: Boolean = false, dates: Boolean = false, hasChildren: Boolean = true): String {
        fun row(id: String, text: String, depth: Int): JSONObject {
            val block = JSONObject().put("uuid", id).put("title", text).put("pageId", "spacing-journal")
                .put("journalTitle", journal).put("journalDay", 20261022)
            if (priority && id == "parent") block.put("priority", JSONObject()
                .put("uuid", "priority-high").put("ident", "logseq.property.priority/high").put("title", "High"))
            if (status && id == "parent") block.put("status", JSONObject()
                .put("uuid", "todo").put("ident", "logseq.property.status/todo").put("title", "Todo"))
            if (dates) block.put("taskDates", JSONObject().put("ownerUuid", id).put("properties", JSONArray().put(JSONObject()
                .put("attr", "logseq.property/scheduled").put("title", "Scheduled").put("kind", "datetime")
                .put("text", "Oct 23, 09:30").put("editorValue", "1792719000000").put("editable", true))))
            return JSONObject().put("depth", depth).put("hasChildren", depth == 0 && hasChildren).put("block", block)
        }
        val state = JSONObject()
        if (editing) state.put("editing", JSONObject().put("uuid", "parent")
            .put("title", "Parent note").put("caretUTF16Offset", 0))
        return JSONObject().put("ok", true).put("result", JSONObject()
            .put("graphName", "Spacing test").put("selectedGraphId", "spacing-test")
            .put("isGraphUnlocked", true).put("outlinerState", state)
            .put("outlinerRows", JSONArray().put(row("parent", "Parent note", 0))
                .put(row("child", "Child note", 1)))).toString()
    }

    private fun render(editing: Boolean = false) {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(onEvent = { events.add(it); dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        filter.applyJson(native.applySnapshot(snapshot(editing)))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(root) }
            }
        }
    }

    private fun gap(editing: Boolean = false) =
        (if (editing) ui.onNodeWithTag("field.outliner.block.parent") else ui.onNodeWithText("Parent note"))
            .getUnclippedBoundsInRoot().left -
            ui.onNodeWithTag("outliner.bullet-glyph.parent").getUnclippedBoundsInRoot().right

    @Test fun ordinaryTextDoesNotReserveAnEmptyPriorityGap() {
        render()
        assertTrue("Compact document text follows the bullet slot: ${gap()}", gap() in 0.dp..4.dp)
    }

    @Test fun editingKeepsTheSameCompactTextColumn() {
        render(editing = true)
        assertTrue("Editing does not reserve an empty priority gap: ${gap(true)}", gap(true) in 0.dp..4.dp)
    }

    @Test fun theBulletCenterAlignsWithTheJournalTitleLeadingEdge() {
        render()
        val heading = ui.onAllNodesWithText(journal, useUnmergedTree = true).fetchSemanticsNodes()
            .maxBy { it.boundsInRoot.height }.boundsInRoot
        val bullet = ui.onNodeWithTag("outliner.bullet-glyph.parent").fetchSemanticsNode().boundsInRoot
        assertEquals("The heading and top-level bullet share one vertical guide", heading.left,
            bullet.center.x, with(ui.density) { 1.dp.toPx() })
    }

    @Test fun nestedBulletsAndTextUseTheSameIndentStep() {
        render()
        val parent = ui.onNodeWithTag("outliner.bullet-glyph.parent").getUnclippedBoundsInRoot()
        val child = ui.onNodeWithTag("outliner.bullet-glyph.child").getUnclippedBoundsInRoot()
        val textIndent = ui.onNodeWithText("Child note").getUnclippedBoundsInRoot().left -
            ui.onNodeWithText("Parent note").getUnclippedBoundsInRoot().left
        assertTrue("Child rows remain visibly indented", child.left > parent.left)
        assertEquals((child.left - parent.left).value, textIndent.value, 0.5f)
    }

    @Test fun addingAndRemovingPriorityDoesNotLeaveAnEmptyColumn() {
        render()
        val initial = gap()
        ui.runOnIdle { filter.applyJson(requireNotNull(bridge).applySnapshot(snapshot(priority = true))) }
        assertTrue("A visible priority retains its own space", gap() > initial)
        ui.runOnIdle { filter.applyJson(requireNotNull(bridge).applySnapshot(snapshot())) }
        assertTrue("Removing priority returns to compact spacing", gap() in 0.dp..4.dp)
    }


    @Test fun disclosureDoesNotAddABlankLineBeforeChildren() {
        render()
        val collapse = ui.onNodeWithTag("button.outliner.collapse.parent")
        collapse.assertTouchWidthIsEqualTo(48.dp).assertTouchHeightIsEqualTo(48.dp)
        val before = ui.onNodeWithText("Child note").getUnclippedBoundsInRoot().top -
            ui.onNodeWithText("Parent note").getUnclippedBoundsInRoot().top
        ui.runOnIdle { filter.applyJson(requireNotNull(bridge).applySnapshot(snapshot(hasChildren = false))) }
        val after = ui.onNodeWithText("Child note").getUnclippedBoundsInRoot().top -
            ui.onNodeWithText("Parent note").getUnclippedBoundsInRoot().top
        assertEquals("A disclosure must not change document row spacing", after.value, before.value, 0.5f)
    }

    @Test fun taskDatePropertiesAlignWithBlockText() {
        render()
        for (variant in 0..3) {
            ui.runOnIdle { filter.applyJson(requireNotNull(bridge).applySnapshot(
                snapshot(priority = variant and 1 != 0, status = variant and 2 != 0, dates = true))) }
            for ((id, text) in listOf("parent" to "Parent note", "child" to "Child note")) {
                val label = ui.onNodeWithTag("property.label.$id.logseq.property/scheduled").getUnclippedBoundsInRoot()
                val title = ui.onNodeWithText(text).getUnclippedBoundsInRoot()
                assertEquals("Task dates follow the text edge for variant $variant, $id", title.left.value, label.left.value, 1f)
            }
        }
    }

    @Test fun compactBulletsKeepNativeTouchTargetsAndOneZoomAction() {
        render()
        val zoom = ui.onNodeWithTag("button.outliner.zoom.parent.Parent note")
        zoom.assertIsDisplayed().assertTouchWidthIsEqualTo(48.dp).assertTouchHeightIsEqualTo(48.dp)
        ui.runOnIdle { events.clear() }
        zoom.performTouchInput { click(center) }
        ui.runOnIdle { assertEquals(1, events.filterIsInstance<LuiEvent.Press>().size) }
    }
}
