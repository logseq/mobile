package com.logseq.logseq

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.logseq.runtime.LogseqNativeBridge
import com.logseq.logseq.runtime.LuiPatchFilter
import com.logseq.logseq.runtime.dispatchLuiEvent
import com.logseq.logseq.runtime.logseqIconResolver
import com.logseq.logseq.ui.LogseqTheme
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONObject
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidQueryResultViewsTest {
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge
    private lateinit var backend: LuiBackend
    private lateinit var filter: LuiPatchFilter

    @After fun closeBridge() {
        if (::bridge.isInitialized) ui.runOnIdle { bridge.close() }
    }

    private fun mount(transform: (JSONObject) -> Unit = {}) {
        backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        val snapshot = InstrumentationRegistry.getInstrumentation().context.assets
            .open("query-result-views.json").bufferedReader().use { it.readText() }
        val response = JSONObject(snapshot)
        transform(response.getJSONObject("result"))
        filter.applyJson(bridge.applySnapshot(response.toString()))
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let { filter.applyJson(it) }
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(root) }
            }
        }
    }

    private fun capture(name: String) {
        val directory = requireNotNull(InstrumentationRegistry.getInstrumentation()
            .targetContext.getExternalFilesDir("qa"))
        directory.mkdirs()
        directory.resolve("query-$name.png").outputStream().use {
            ui.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun outlinerStatusPickerAndEditorToolbarKeepTheRowInSync() {
        val blockId = "task-row"
        val todo = JSONObject().put("uuid", "todo").put("title", "Todo")
            .put("ident", "logseq.property/status.todo")
        val doing = JSONObject().put("uuid", "doing").put("title", "Doing")
            .put("ident", "logseq.property/status.doing")
        lateinit var result: JSONObject
        mount { snapshot ->
            result = snapshot
            val block = JSONObject().put("uuid", blockId).put("title", "Test task").put("pageId", "page")
                .put("isTask", true).put("status", todo)
            snapshot.put("outlinerRows", JSONArray().put(JSONObject().put("block", block).put("depth", 0)))
                .put("taskStatuses", JSONArray().put(todo).put(doing))
        }
        val status = ui.onNodeWithTag("button.block-task-status")
        val todoOption = ui.onNodeWithTag("button.block-task-status-option.logseq.property/status.todo")
        val doingOption = ui.onNodeWithTag("button.block-task-status-option.logseq.property/status.doing")
        val field = ui.onNodeWithTag("field.outliner.block.$blockId")
        field.assertDoesNotExist()
        status.assertContentDescriptionEquals("Todo").performClick()
        todoOption.assertIsSelected()
        doingOption.assertIsDisplayed()
        assertTrue(InstrumentationRegistry.getInstrumentation().uiAutomation
            .performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK))
        status.assertContentDescriptionEquals("Todo")
        ui.runOnIdle {
            check(takeEffect("set-outliner-task-status") == null) { "Dismissing the menu must not change status" }
        }

        status.performClick()
        doingOption.performClick()
        ui.runOnIdle {
            val effect = requireNotNull(takeEffect("set-outliner-task-status"))
            assertEquals(blockId, effect.getString("text"))
            assertEquals("doing", JSONObject(effect.getString("metadata")).getString("uuid"))
            result.put("outlinerState", JSONObject().put("editing", JSONObject().put("uuid", blockId)
                .put("title", "Test task").put("caretUTF16Offset", 0)))
            filter.applyJson(bridge.applySnapshot(JSONObject().put("ok", true).put("result", result).toString()))
        }

        field.assertIsDisplayed()
        status.assertContentDescriptionEquals("Todo")
        ui.onNodeWithTag("button.outliner.editor.task").performClick()
        ui.runOnIdle {
            val effect = requireNotNull(takeEffect("outliner-toolbar"))
            assertEquals("task", effect.getString("text"))
            val block = result.getJSONArray("outlinerRows").getJSONObject(0).getJSONObject("block")
            block.put("status", doing)
            filter.applyJson(bridge.applySnapshot(JSONObject().put("ok", true).put("result", result).toString()))
        }
        status.assertContentDescriptionEquals("Doing")
        field.assertIsDisplayed()
    }

    private fun takeEffect(kind: String): JSONObject? {
        repeat(32) {
            val encoded = bridge.takeEffect()
            if (encoded.isEmpty()) return null
            val effect = JSONObject(encoded).optJSONObject("effect")
            if (effect?.optString("kind") == kind) return effect
        }
        return null
    }

    private fun assertFullTabLabel(text: String) {
        val layouts = mutableListOf<TextLayoutResult>()
        ui.onNodeWithText(text, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue("The selected native tab must show its full label",
            layouts.isNotEmpty() && layouts.none { it.isLineEllipsized(0) })
    }

    private var selectedView = "list"

    private fun assertVirtualResults(type: String) {
        var updatedSnapshot = JSONObject()
        mount { result ->
            val query = result.getJSONArray("outlinerRows").getJSONObject(0).getJSONObject("block").getJSONObject("query")
            val view = query.getJSONArray("views").let { views ->
                (0 until views.length()).map { views.getJSONObject(it) }.first { it.getString("uuid") == type }
            }
            val rows = JSONArray()
            repeat(10_001) { index ->
                val title = "Object %05d".format(index)
                rows.put(JSONObject().put("block", JSONObject().put("uuid", "virtual-$index")
                    .put("title", title).put("pageId", "page"))
                    .put("properties", JSONArray().put(JSONObject().put("attr", "block/title")
                        .put("text", title).put("editable", true)
                        .put("raw", JSONObject().put("type", "string").put("value", title)))))
            }
            view.put("rows", rows)
            query.put("views", JSONArray().put(view)).put("expanded", true)
            updatedSnapshot = JSONObject().put("ok", true).put("result", result)
        }
        val first = if (type == "table") "view.cell.table.virtual-0.block/title" else "view.card.gallery.virtual-0"
        val last = if (type == "table") "view.cell.table.virtual-10000.block/title" else "view.card.gallery.virtual-10000"
        val viewport = if (type == "table") "view.table.viewport.table" else "view.gallery.gallery"
        ui.onNodeWithTag(viewport).assertIsDisplayed()
        ui.onNodeWithTag(first).assertIsDisplayed()
        ui.onNodeWithTag(last).assertDoesNotExist()
        ui.onNodeWithTag(viewport).performScrollToIndex(10_000)
        ui.onNodeWithTag(last).assertIsDisplayed()
        ui.onNodeWithTag(first).assertDoesNotExist()
        capture("virtual-$type-last")
        if (type == "table") {
            ui.onNodeWithTag(last).performClick()
            ui.onNodeWithTag("view.edit.value.table").assertIsDisplayed()
            ui.onNodeWithTag("view.edit.cancel.table").performClick()
        }
        ui.runOnIdle {
            val row = updatedSnapshot.getJSONObject("result").getJSONArray("outlinerRows").getJSONObject(0)
                .getJSONObject("block").getJSONObject("query").getJSONArray("views").getJSONObject(0)
                .getJSONArray("rows").getJSONObject(10_000)
            val title = "Updated object 10000"
            row.getJSONObject("block").put("title", title)
            row.getJSONArray("properties").getJSONObject(0).put("text", title)
                .getJSONObject("raw").put("value", title)
            filter.applyJson(bridge.applySnapshot(updatedSnapshot.toString()))
        }
        ui.onNodeWithTag(last).assertIsDisplayed()
        ui.onNodeWithText("Updated object 10000", useUnmergedTree = true).assertIsDisplayed()
        ui.onNodeWithTag(viewport).performScrollToIndex(0)
        ui.onNodeWithTag(first).assertIsDisplayed()
        ui.onNodeWithTag(last).assertDoesNotExist()
        ui.runOnIdle { assertNull(backend.lastError) }
    }

    @Test fun tableVirtualizesLargeResultsAndEditsDistantCells() = assertVirtualResults("table")
    @Test fun galleryVirtualizesLargeResultsAndRestoresEarlierCards() = assertVirtualResults("gallery")

    @Test fun allViewSelectorAlignsLeadingAndKeepsAdaptiveWidth() {
        mount { result ->
            result.put("selectedPage", JSONObject().put("uuid", "collection").put("title", "Collection"))
            result.put("selectedPageIsTag", true)
            result.put("resultViews", JSONObject().put("ownerUuid", "collection").put("featureType", "tagged")
                .put("views", JSONArray().put(JSONObject().put("uuid", "all").put("name", "All")
                    .put("type", "list").put("rows", JSONArray()))))
        }
        val selector = ui.onNodeWithTag("view.select.collection").assertIsDisplayed()
        val label = ui.onNodeWithText("All", useUnmergedTree = true).assertIsDisplayed()
        val controlBounds = selector.getUnclippedBoundsInRoot()
        val textBounds = label.getUnclippedBoundsInRoot()
        assertTrue("All must align with the native selector's leading edge",
            kotlin.math.abs(controlBounds.left.value - textBounds.left.value) <= 1f)
        assertTrue("The selector must retain an adaptive width", (controlBounds.right - controlBounds.left).value < 100f)
        selector.performClick()
        ui.onNodeWithTag("view.tab.all").assertIsDisplayed()
    }

    private fun selectView(name: String) {
        ui.onNodeWithTag("view.type.$selectedView").performClick()
        ui.onNodeWithText("Saved views").performClick()
        ui.onNodeWithTag("view.tab.$name").performClick()
        selectedView = name
    }

    @Test fun priorityGlyphOpensNativePopupAndSendsSelectedReference() {
        mount { result ->
            val choice = JSONObject().put("uuid", "critical").put("title", "Critical")
                .put("iconType", "tabler-icon").put("iconId", "priorityLvlHigh")
            result.put("taskPriorities", JSONArray().put(choice))
            fun visit(value: Any?) {
                when (value) {
                    is JSONObject -> {
                        if (value.optString("uuid") == "result-0") value.put("priority", choice)
                        value.keys().asSequence().toList().forEach { visit(value.opt(it)) }
                    }
                    is JSONArray -> (0 until value.length()).forEach { visit(value.opt(it)) }
                }
            }
            visit(result.getJSONArray("outlinerRows"))
        }
        ui.onNodeWithTag("button.block-task-priority").performClick()
        ui.onNodeWithText("Critical").assertIsDisplayed()
        ui.onNodeWithTag("button.block-task-priority-option.critical").assertIsSelected()
        capture("priority-popup")
        ui.onNodeWithTag("button.block-task-priority-option.critical").performClick()
        ui.runOnIdle {
            var found = false
            repeat(32) {
                val encoded = bridge.takeEffect()
                if (encoded.isNotEmpty()) {
                    val effect = JSONObject(encoded).optJSONObject("effect")
                    if (effect?.optString("kind") == "set-outliner-task-priority") {
                        assertEquals("result-0", effect.getString("text"))
                        assertEquals("critical", JSONObject(effect.getString("metadata")).getString("uuid"))
                        found = true
                    }
                }
            }
            check(found) { "Selecting a priority must dispatch its stable reference" }
            assertNull(backend.lastError)
        }
    }

    @Test fun queryResultOpensAnAttachmentOutsideTheActiveOutliner() {
        val file = "/tmp/query-attachment.txt"
        mount { result ->
            val query = result.getJSONArray("outlinerRows").getJSONObject(0)
                .getJSONObject("block").getJSONObject("query")
            val attachment = JSONObject().put("uuid", "external-file").put("title", "Query attachment.txt")
                .put("pageId", "other-page").put("isAsset", true).put("assetType", "text/plain")
                .put("localPath", file)
            query.getJSONArray("rows").getJSONObject(0).put("block", attachment)
            val views = query.getJSONArray("views")
            for (index in 0 until views.length()) {
                val view = views.getJSONObject(index)
                if (view.optString("type") == "list") {
                    view.put("rows", JSONArray().put(JSONObject().put("block", attachment)))
                }
            }
        }
        ui.onNodeWithText("Query attachment.txt").performClick()
        ui.runOnIdle {
            val effect = requireNotNull(takeEffect("present-asset"))
            val metadata = JSONObject(effect.getString("metadata"))
            assertEquals(file, metadata.getString("localPath"))
            assertEquals("text/plain", metadata.getString("assetType"))
        }
    }

    private fun takeViewActions(): List<JSONObject> {
        val actions = mutableListOf<JSONObject>()
        ui.runOnIdle {
            repeat(32) {
                val encoded = bridge.takeEffect()
                if (encoded.isNotEmpty()) {
                    val effect = JSONObject(encoded).optJSONObject("effect")
                    if (effect?.optString("kind") == "result-view") actions.add(JSONObject(effect.getString("text")))
                }
            }
        }
        return actions
    }

    @Test fun typeIconOpensChoicesForTheSelectedSavedView() {
        mount()
        ui.onNodeWithTag("view.type.list").performClick()
        ui.onNodeWithTag("view.type.option.list.list").assertIsDisplayed()
        ui.onNodeWithTag("view.type.option.list.table").assertIsDisplayed()
        ui.onNodeWithTag("view.type.option.list.gallery").performClick()
        val action = takeViewActions().single()
        assertEquals("list", action.getString("viewUuid"))
        assertEquals("gallery", action.getJSONObject("config").getString("type"))
    }

    private fun assertObjectPageHidesBlocks(property: Boolean) {
        mount { result ->
            val query = result.getJSONArray("outlinerRows").getJSONObject(0).getJSONObject("block").getJSONObject("query")
            result.put("selectedPage", JSONObject().put("uuid", "collection").put("title", "Collection"))
                .put("selectedPageIsTag", !property).put("selectedPageIsProperty", property)
                .put("resultViews", query)
        }
        ui.onNodeWithTag("outliner.block.query-owner").assertDoesNotExist()
        ui.onNodeWithTag("button.outliner.placeholder.collection").assertDoesNotExist()
        ui.onNodeWithText("Project result 1").assertIsDisplayed()
        capture(if (property) "property-objects" else "tag-objects")
    }

    @Test fun tagPageHidesBlocksAndPlaceholderButShowsObjects() = assertObjectPageHidesBlocks(false)
    @Test fun propertyPageHidesBlocksAndPlaceholderButShowsObjects() = assertObjectPageHidesBlocks(true)

    @Test fun foldedQueryResultsLoadOnlyWhenTapped() {
        mount { result ->
            val query = result.getJSONArray("outlinerRows").getJSONObject(0).getJSONObject("block").getJSONObject("query")
            query.put("expanded", false).put("views", JSONArray()).put("rows", JSONArray())
        }
        ui.onNodeWithText("Project result 1").assertDoesNotExist()
        assertTrue("Mounting folded queries must not request results", takeViewActions().isEmpty())
        ui.onNodeWithTag("query.toggle.query-owner").performClick()
        val action = takeViewActions().single()
        assertEquals("setExpanded", action.getString("action"))
        assertTrue(action.getBoolean("expanded"))
    }

    @Test fun savedListsAndGallerySearchRecoverAfterSelectingAnInvalidView() {
        mount()
        ui.onNodeWithText("Project result 1").assertIsDisplayed()
        ui.onNodeWithText("Nested child").assertDoesNotExist()
        capture("list")
        selectView("gallery")
        ui.onNodeWithTag("view.card.gallery.result-0").assertIsDisplayed()
        capture("gallery")
        ui.onNodeWithTag("view.search.toggle.query-owner").performClick()
        val search = ui.onNodeWithTag("view.search.query-owner").getUnclippedBoundsInRoot()
        val toolbar = ui.onNodeWithTag("view.toolbar.query-owner").getUnclippedBoundsInRoot()
        assertEquals("Search fills the collection width", toolbar.right.value, search.right.value, 1f)
        ui.onNodeWithTag("view.search.query-owner").performTextReplacement("result 1")
        ui.onNodeWithTag("view.card.gallery.result-1").assertDoesNotExist()
        selectView("broken")
        ui.onNodeWithTag("view.type.broken").assertIsDisplayed()
        ui.onNodeWithTag("view.table.scroll.broken").assertDoesNotExist()
        selectView("list")
        ui.onNodeWithText("Project result 1").assertIsDisplayed()
        ui.runOnIdle { assertNull(backend.lastError) }
    }

    @Test fun horizontalTablesDeliverTypedEditsAndPresentFilterSortSettings() {
        mount()
        val bullet = ui.onNodeWithTag("outliner.bullet-glyph.query-owner", useUnmergedTree = true)
            .getUnclippedBoundsInRoot()
        val toolbar = ui.onNodeWithTag("view.toolbar.query-owner", useUnmergedTree = true)
            .getUnclippedBoundsInRoot()
        assertEquals("The collection starts at the owning bullet center",
            (bullet.left.value + bullet.right.value) / 2, toolbar.left.value, 0.5f)
        selectView("table")
        ui.onNodeWithTag("view.type.table").assertIsDisplayed()
        ui.onNodeWithTag("view.table.scroll.table").assertIsDisplayed()
        ui.onNodeWithTag("view.table.scroll.table").performTouchInput { swipeLeft() }
        ui.onNodeWithTag("view.table.scroll.table").performTouchInput { swipeRight() }
        ui.onNodeWithTag("sidebar.content").assertIsNotDisplayed()
        ui.onNodeWithTag("view.cell.table.result-0.block/title").performClick()
        ui.onNodeWithTag("view.edit.value.table").assertIsDisplayed()
        ui.onNodeWithTag("view.edit.clear.table").assertDoesNotExist()
        ui.onNodeWithTag("view.edit.cancel.table").performClick()
        ui.onNodeWithTag("view.edit.sheet.table").assertDoesNotExist()
        for (attr in listOf("user.property/Score")) {
            val header = ui.onNodeWithTag("view.cell.separator.table.header.$attr", useUnmergedTree = true)
                .getUnclippedBoundsInRoot()
            for (row in listOf("result-0", "result-1", "result-2")) {
                val divider = ui.onNodeWithTag("view.cell.separator.table.$row.$attr", useUnmergedTree = true)
                    .getUnclippedBoundsInRoot()
                assertEquals("Column dividers stay one point wide", 1f, (divider.right - divider.left).value, 0.2f)
                assertTrue("Column dividers span the cell height", (divider.bottom - divider.top).value >= 48f)
                assertEquals("Header and body dividers align", header.left.value, divider.left.value, 0.5f)
            }
        }
        capture("table")
        ui.onNodeWithTag("view.cell.table.result-0.user.property/Score")
            .performScrollTo().performClick()
        ui.onNodeWithTag("view.edit.value.table").performTextReplacement("35")
        capture("cell-editor")
        ui.onNodeWithTag("view.edit.create.table").performClick()
        ui.runOnIdle {
            var found = false
            repeat(32) {
                val encoded = bridge.takeEffect()
                if (encoded.isNotEmpty()) {
                    val dispatch = JSONObject(encoded)
                    val effect = dispatch.optJSONObject("effect")
                    if (effect?.optString("kind") == "result-view") {
                        val payload = JSONObject(effect.getString("text"))
                        assertEquals("editCell", payload.getString("action"))
                        assertEquals("35", payload.getString("value"))
                        bridge.resolveEffect(effect.getLong("id"), true, "").takeIf { it.isNotEmpty() }?.let { filter.applyJson(it) }
                        found = true
                    }
                }
            }
            check(found) { "The native editor must send a core result-view mutation" }
        }
        ui.onNodeWithTag("view.edit.value.table").assertDoesNotExist()
        ui.onNodeWithTag("view.filter.table").performClick()
        ui.onNodeWithTag("view.filter.list.table").assertIsDisplayed()
        val settingsTop = ui.onNodeWithText("Filters").fetchSemanticsNode().boundsInWindow.top
        val screenHeight = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.heightPixels
        assertTrue("Utility sheets should open partially and remain expandable", settingsTop > screenHeight * 0.25f)
        ui.onNodeWithTag("view.filter.add.table").performClick()
        capture("settings")
        ui.onNodeWithTag("view.settings.cancel.table").performClick()
        selectView("list")
        ui.onNodeWithText("Project result 1").assertIsDisplayed()
        ui.runOnIdle { assertNull(backend.lastError) }
    }
}
