package com.logseq.logseq

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTouchHeightIsEqualTo
import androidx.compose.ui.test.assertTouchWidthIsEqualTo
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.click
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.logseq.runtime.LogseqNativeBridge
import com.logseq.logseq.runtime.LuiPatchFilter
import com.logseq.logseq.runtime.dispatchLuiEvent
import com.logseq.logseq.runtime.logseqIconResolver
import com.logseq.logseq.ui.LogseqTheme
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlinx.coroutines.runBlocking
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
    private var swipeFixture: File? = null

    @After fun closeBridge() {
        bridge?.let { ui.runOnIdle { it.close() } }
        swipeFixture?.deleteRecursively()
    }

    private fun snapshot(editing: Boolean = false, priority: Boolean = false, status: Boolean = false, dates: Boolean = false, hasChildren: Boolean = true, editingUuid: String = "parent"): String {
        fun row(id: String, text: String, depth: Int): JSONObject {
            val block = JSONObject().put("uuid", id).put("title", text).put("pageId", "spacing-journal")
                .put("journalTitle", journal).put("journalDay", 20261022)
            if (priority && id == "parent") block.put("priority", JSONObject()
                .put("uuid", "priority-high").put("ident", "logseq.property.priority/high").put("title", "High"))
            if (status && id == "parent") block.put("status", JSONObject()
                .put("uuid", "todo").put("ident", "logseq.property.status/todo").put("title", "Todo"))
            if (dates) block.put("taskDates", JSONObject().put("ownerUuid", id).put("properties", JSONArray().apply {
                for (name in listOf("scheduled", "deadline")) put(JSONObject()
                    .put("attr", "logseq.property/$name").put("title", name.replaceFirstChar { it.uppercase() }).put("kind", "datetime")
                    .put("text", "Oct 23, 09:30").put("editorValue", "1792719000000").put("editable", true))
            }))
            return JSONObject().put("depth", depth).put("hasChildren", depth == 0 && hasChildren).put("block", block)
        }
        val state = JSONObject()
        if (editing) state.put("editing", JSONObject().put("uuid", editingUuid)
            .put("title", if (editingUuid == "parent") "Parent note" else "Child note").put("caretUTF16Offset", 0))
        return JSONObject().put("ok", true).put("result", JSONObject()
            .put("graphName", "Spacing test").put("selectedGraphId", "spacing-test")
            .put("isGraphUnlocked", true).put("outlinerState", state)
            .put("outlinerRows", JSONArray().put(row("parent", "Parent note", 0))
                .put(row("child", "Child note", 1)))).toString()
    }

    private fun render(
        editing: Boolean = false,
        initialSnapshot: (LogseqNativeBridge) -> String = { snapshot(editing) },
    ) {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(onEvent = { events.add(it); dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        filter.applyJson(native.applySnapshot(initialSnapshot(native)))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(root) }
            }
        }
    }

    private fun requestCore(native: LogseqNativeBridge, action: String? = null, payload: String? = null, path: String? = null): String =
        runBlocking {
            val params = JSONObject().put("action", action).put("payload", payload).put("path", path)
            val method = if (action == null) "open" else "dispatch"
            native.callCore(JSONObject().put("apiVersion", 1).put("method", method).put("params", params).toString())
                .also { assertTrue(it, JSONObject(it).getBoolean("ok")) }
        }

    private fun openSwipeTask(native: LogseqNativeBridge, uuid: String): String {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "swipe-task").toFile()
        swipeFixture = directory
        val database = File(directory, "graph.sqlite")
        val checkpoint = File(directory, "sync.checkpoint")
        for (file in listOf(database, checkpoint)) {
            instrumentation.context.assets.open("feedback/${file.name}").use { input ->
                file.outputStream().use(input::copyTo)
            }
        }
        requestCore(native, path = File(directory, "logseq.sqlite").path)
        requestCore(native, "configure", """{"graphId":"feedback","baseUrl":"http://127.0.0.1:1","token":""}""")
        requestCore(native, "openGraph", JSONObject().put("graphId", "feedback")
            .put("activePath", database.path).put("checkpointPath", checkpoint.path).put("isEncrypted", false).toString())
        requestCore(native, "selectPage", "f0000000-0000-4000-8000-000000000001")
        requestCore(native, "outlinerEvent", JSONObject()
            .put("type", "setTaskStatus").put("uuid", uuid)
            .put("statusIdent", "logseq.property/status.doing").toString())
        return requestCore(native, "refresh")
    }

    private fun gap(editing: Boolean = false) =
        (if (editing) ui.onNodeWithTag("field.outliner.block.parent") else ui.onNodeWithText("Parent note"))
            .getUnclippedBoundsInRoot().left -
            ui.onNodeWithTag("outliner.bullet-glyph.parent", useUnmergedTree = true).getUnclippedBoundsInRoot().right

    @Test fun ordinaryTextDoesNotReserveAnEmptyPriorityGap() {
        render()
        assertTrue("Compact document text follows the bullet slot: ${gap()}", gap() in 0.dp..4.dp)
    }

    @Test fun selectionSwipeMovesTheTaskMarkersWithTheText() {
        val uuid = "f0000000-0000-4000-8000-000000000011"
        render { openSwipeTask(it, uuid) }
        val body = ui.onNodeWithTag("outliner-block-content-$uuid")
        val bullet = ui.onNodeWithTag("outliner.bullet-glyph.$uuid", useUnmergedTree = true)
        val parts = listOf(
            bullet,
            ui.onNodeWithTag("outliner.task-status-icon.$uuid"),
            ui.onNodeWithText("Journal content"),
        )
        fun positions() = parts.map { it.getUnclippedBoundsInRoot().left }
        val resting = positions()
        fun assertMarkersFollow() {
            val displacement = resting.zip(positions()) { before, during -> before - during }
            assertTrue("The bullet follows the active drag", displacement.first() > 4.dp)
            assertTrue("The bullet, status and text share the same displacement: $displacement",
                displacement.all { it in (displacement.first() - 1.dp)..(displacement.first() + 1.dp) })
        }
        body.performTouchInput {
            down(center)
            moveTo(center - Offset(width * .04f, 0f))
            moveTo(center - Offset(width * .08f, 0f))
        }
        assertMarkersFollow()
        body.performTouchInput { cancel() }
        assertEquals(resting, positions())
        ui.onNodeWithTag("toolbar.outliner.selection").assertDoesNotExist()

        body.performTouchInput {
            down(center)
            moveTo(center - Offset(width * .20f, 0f))
            moveTo(center - Offset(width * .40f, 0f))
        }
        assertMarkersFollow()
        val bulletBounds = bullet.getUnclippedBoundsInRoot()
        assertTrue("The bullet remains inside the viewport at full travel",
            (bulletBounds.left + bulletBounds.right) / 2 >= 8.5.dp)
        body.performTouchInput { up() }

        val native = requireNotNull(bridge)
        val effect = ui.runOnIdle {
            assertEquals(listOf(uuid), events.filterIsInstance<LuiEvent.Extension>()
                .filter { it.name == "toggle-selection" }.map { it.values["uuid"] })
            generateSequence { native.takeEffect().takeIf { it.isNotEmpty() } }
                .map { JSONObject(it) }
                .onEach { it.optString("patch").takeIf { patch -> patch.isNotEmpty() }?.let(filter::applyJson) }
                .mapNotNull { it.optJSONObject("effect") }
                .first { it.getString("kind") == "editor-outliner-event" }
        }
        val response = requestCore(native, "executeEffect", effect.toString())
        val selected = JSONObject(response).getJSONObject("result").getJSONObject("outlinerState")
            .getJSONArray("selectedBlockIds")
        assertEquals(1, selected.length())
        assertEquals(uuid, selected.getString(0))
        ui.runOnIdle {
            native.applySnapshot(response).takeIf { it.isNotEmpty() }?.let(filter::applyJson)
            native.resolveEffect(effect.getLong("id"), true, "").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        }
        ui.onNodeWithTag("toolbar.outliner.selection").assertIsDisplayed()
    }

    @Test fun editingKeepsTheSameCompactTextColumn() {
        render(editing = true)
        assertTrue("Editing does not reserve an empty priority gap: ${gap(true)}", gap(true) in 0.dp..4.dp)
    }

    @Test fun tappingBlockTextKeepsTheTextLayoutWhenTheEditorOpens() {
        render()
        val content = ui.onNodeWithTag("outliner-block-content-parent")
        val body = ui.onNodeWithText("Parent note")
        val before = mutableListOf<TextLayoutResult>()
        body.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(before) }
        val initialLeft = body.getUnclippedBoundsInRoot().left
        content.performTouchInput { click(center) }
        ui.runOnIdle {
            assertTrue(events.filterIsInstance<LuiEvent.Extension>().any { it.name == "edit" })
            filter.applyJson(requireNotNull(bridge).applySnapshot(snapshot(editing = true)))
        }
        val editor = ui.onNodeWithTag("field.outliner.block.parent").assertIsFocused()
        val after = mutableListOf<TextLayoutResult>()
        editor.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(after) }
        assertEquals(initialLeft, editor.getUnclippedBoundsInRoot().left)
        assertEquals(before.single().getLineRight(0), after.single().getLineRight(0), 0.5f)
        assertEquals(before.single().firstBaseline, after.single().firstBaseline, 0.5f)
    }

    @Test fun tappingBetweenBlocksKeepsEachTitleInTheFirstEditorFrame() {
        render(editing = true)
        val editorId = ui.onNodeWithTag("field.outliner.block.parent").assertIsFocused().fetchSemanticsNode().id
        for (uuid in listOf("child", "parent", "child")) {
            ui.onNodeWithTag("outliner-block-content-$uuid").performTouchInput { click(center) }
            ui.mainClock.autoAdvance = false
            try {
                ui.runOnUiThread {
                    filter.applyJson(requireNotNull(bridge).applySnapshot(snapshot(editing = true, editingUuid = uuid)))
                }
                ui.mainClock.advanceTimeByFrame()
                val editor = ui.onNodeWithTag("field.outliner.block.$uuid").assertIsFocused()
                    .assertTextEquals(if (uuid == "parent") "Parent note" else "Child note")
                assertEquals("Switching blocks reuses the native editor", editorId, editor.fetchSemanticsNode().id)
                ui.onNodeWithTag("outliner-block-content-${if (uuid == "parent") "child" else "parent"}").assertIsDisplayed()
            } finally { ui.mainClock.autoAdvance = true }
        }
    }

    @Test fun theBulletCenterAlignsWithTheJournalTitleLeadingEdge() {
        render()
        val heading = ui.onAllNodesWithText(journal, useUnmergedTree = true).fetchSemanticsNodes()
            .maxBy { it.boundsInRoot.height }.boundsInRoot
        val bullet = ui.onNodeWithTag("outliner.bullet-glyph.parent", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals("The heading and top-level bullet share one vertical guide", heading.left,
            bullet.center.x, with(ui.density) { 1.dp.toPx() })
    }

    @Test fun pageHeadingAndTaskGlyphAlignWithTheirOutlinerColumns() {
        render {
            val response = JSONObject(snapshot(status = true))
            val result = response.getJSONObject("result")
            result.put("selectedPage", JSONObject().put("uuid", "spacing-journal").put("title", "Project notes"))
            result.getJSONArray("outlinerRows").getJSONObject(1).put("depth", 0)
            response.toString()
        }
        val heading = ui.onNodeWithTag("title.selected-page", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val bullet = ui.onNodeWithTag("outliner.bullet-glyph.parent", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val glyph = ui.onNodeWithTag("outliner.task-status-icon.parent").fetchSemanticsNode().boundsInRoot
        val plainText = ui.onNodeWithText("Child note").fetchSemanticsNode().boundsInRoot
        val tolerance = with(ui.density) { 1.dp.toPx() }
        assertEquals("Top-level bullets align with the page title", heading.left, bullet.center.x, tolerance)
        assertEquals("Visible status icons align with ordinary block text", plainText.left, glyph.left, tolerance)
    }

    @Test fun compactLongPressMenuHighlightsTheBulletAndSelectKeepsItHighlighted() {
        render()
        val bullet = ui.onNodeWithTag("outliner.bullet-glyph.parent", useUnmergedTree = true)
        fun bulletBackground(): Int {
            val image = bullet.captureToImage().asAndroidBitmap()
            return image.getPixel(image.width / 4, image.height / 2)
        }
        val resting = bulletBackground()
        ui.onNodeWithTag("outliner-block-content-parent").performTouchInput { longClick() }
        val menu = ui.onNodeWithTag("outliner.block.menu").assertIsDisplayed().getUnclippedBoundsInRoot()
        assertEquals(256f, (menu.right - menu.left).value, 1f)
        assertTrue("The first menu level fits its primary actions", menu.bottom - menu.top < 380.dp)
        assertTrue("The long press highlights the bullet gutter", bulletBackground() != resting)
        ui.onNodeWithText("Select").performClick()
        ui.runOnIdle {
            val event = events.filterIsInstance<LuiEvent.Extension>().last()
            assertEquals("menu-action", event.name)
            assertEquals("select", event.values["payload"])
            val response = JSONObject(snapshot())
            response.getJSONObject("result").getJSONObject("outlinerState")
                .put("selectedBlockIds", JSONArray().put("parent"))
            filter.applyJson(requireNotNull(bridge).applySnapshot(response.toString()))
        }
        assertTrue("The selection still covers the bullet after dismissal", bulletBackground() != resting)
    }

    @Test fun nestedBulletsAndTextUseTheSameIndentStep() {
        render()
        val parent = ui.onNodeWithTag("outliner.bullet-glyph.parent", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val child = ui.onNodeWithTag("outliner.bullet-glyph.child", useUnmergedTree = true).getUnclippedBoundsInRoot()
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
                val deadline = ui.onNodeWithTag("property.label.$id.logseq.property/deadline").getUnclippedBoundsInRoot()
                assertEquals("Scheduled and deadline share one line", ((label.top + label.bottom) / 2).value, ((deadline.top + deadline.bottom) / 2).value, 1f)
            }
            val guide = ui.onNodeWithTag("outliner.metadata.guides.parent").captureToImage().asAndroidBitmap()
            val x = with(ui.density) { 12.dp.roundToPx() }
            val reference = guide.getPixel(0, guide.height / 2)
            for (y in 0 until guide.height) {
                assertTrue("The child guide spans the entire metadata region", guide.getPixel(x, y) != reference)
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
