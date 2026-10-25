package com.logseq.app

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
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
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidTagSearchRegressionTest {
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge
    private lateinit var filter: LuiPatchFilter

    @After fun closeBridge() { if (::bridge.isInitialized) ui.runOnIdle { bridge.close() } }

    private fun snapshot(): JSONObject {
        val choices = JSONArray().apply {
            repeat(500) { put(JSONObject().put("title", "PerfTag%03d".format(it))
                .put("match", JSONArray().put("tag-$it"))) }
        }
        return JSONObject().put("ok", true).put("result", JSONObject()
            .put("selectedGraphId", "tag-search").put("graphName", "Tag search")
            .put("selectedPage", JSONObject().put("uuid", "owner").put("title", "Project"))
            .put("outlinerRows", JSONArray().put(JSONObject().put("depth", 0)
                .put("block", JSONObject().put("uuid", "body").put("title", "A tagged block")
                    .put("pageId", "owner").put("tags", JSONArray().put(JSONObject()
                        .put("uuid", "tag-0").put("title", "PerfTag000"))))))
            .put("nodeProperties", JSONObject().put("ownerUuid", "owner").put("canAdd", true)
                .put("classSchema", true).put("properties", JSONArray())
                .put("schemaProperties", JSONArray().put(JSONObject().put("attr", "user.property/Notes").put("title", "Notes")))
                .put("availableProperties", JSONArray().put(JSONObject().put("attr", "user.property/Summary").put("title", "Summary")))
                .put("tagPicker", JSONObject().put("attr", "block/tags").put("title", "Set tags")
                    .put("kind", "class").put("many", true).put("ref", true).put("filterValues", choices)
                    .put("raw", JSONObject().put("type", "set").put("value", JSONArray().put(JSONObject()
                        .put("type", "ref-uuid").put("value", "tag-0")))))))
    }

    private fun render(language: String = "en", response: JSONObject = snapshot(), height: State<Dp>? = null) {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        filter.applyJson(bridge.applySnapshot(response.toString()))
        bridge.applyHostUpdate("settings", """{"appearance":"light","language":"$language","systemLanguage":"en","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"https://api.logseq.io","version":"test","revision":"test"}""")
            .takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Surface(if (height == null) Modifier.fillMaxSize() else Modifier.height(height.value), color = LogseqTheme.lightScheme.background) { backend.Content(root) }
            }
        }
    }

    private fun effects(): List<JSONObject> {
        val result = mutableListOf<JSONObject>()
        ui.runOnIdle {
            repeat(32) {
                val raw = bridge.takeEffect()
                if (raw.isNotEmpty()) JSONObject(raw).optJSONObject("effect")?.let(result::add)
            }
        }
        return result
    }

    @Test fun wideTagTablesMountVisibleCellsAndKeepThePageMenuResponsive() {
        val columns = JSONArray().put(JSONObject().put("attr", "block/title").put("title", "Name"))
        repeat(24) { columns.put(JSONObject().put("attr", "user.property/Column$it").put("title", "Column $it")) }
        val rows = JSONArray()
        repeat(12) { index -> rows.put(JSONObject().put("block", JSONObject().put("uuid", "object-$index")
            .put("title", "Object $index").put("pageId", "owner"))) }
        val response = snapshot()
        response.getJSONObject("result").put("selectedPageIsTag", true).put("outlinerRows", JSONArray())
            .put("resultViews", JSONObject().put("ownerUuid", "owner").put("featureType", "class-objects")
                .put("views", JSONArray().put(JSONObject().put("uuid", "table").put("name", "All").put("type", "table")
                    .put("columns", columns).put("properties", columns).put("rows", rows)
                    .put("rowCount", 1000).put("rowOffset", 0).put("rowsDeferred", true).put("input", "").put("revision", 1))))
        response.getJSONObject("result").getJSONObject("nodeProperties").put("canAdd", false)
        render(response = response)
        ui.onNodeWithTag("view.cell.table.object-0.block/title").assertIsDisplayed()
        ui.onNodeWithTag("view.cell.table.object-0.user.property/Column23").assertDoesNotExist()
        ui.onNodeWithTag("view.table.scroll.table").performTouchInput { swipeLeft() }
        assertTrue(ui.onNodeWithTag("view.table.scroll.table").fetchSemanticsNode()
            .config[SemanticsProperties.HorizontalScrollAxisRange].value() > 0)
        ui.onNodeWithTag("view.table.scroll.table").performSemanticsAction(SemanticsActions.ScrollBy) { it(100000f, 0f) }
        ui.onNodeWithTag("view.cell.table.object-0.user.property/Column23").assertIsDisplayed()
        ui.onNodeWithTag("view.cell.table.object-0.block/title").assertDoesNotExist()
        ui.onNodeWithTag("view.table.viewport.table").performScrollToIndex(999)
        var reads = emptyList<JSONObject>()
        ui.waitUntil(5000) { reads = effects().filter { it.optString("kind") == "load-result-rows" }; reads.isNotEmpty() }
        ui.onNodeWithTag("view.rows.loading.table").assertDoesNotExist()
        val eff = reads.single()
        val request = JSONObject(eff.getString("text"))
        val offset = request.getInt("offset")
        val limit = request.getInt("limit")
        assertTrue(offset > 900 && limit <= 64)
        val loaded = JSONObject(response.getJSONObject("result").getJSONObject("resultViews").getJSONArray("views").getJSONObject(0).toString())
            .put("rowOffset", offset).put("rows", JSONArray().apply {
                for (index in offset until minOf(1000, offset + limit)) put(JSONObject().put("block", JSONObject()
                    .put("uuid", "object-$index").put("title", "Object $index").put("pageId", "owner")))
            })
        val reply = JSONObject().put("ok", true).put("result", JSONObject().put("isQueryPatch", true)
            .put("resultRows", JSONObject().put("key", request.getString("key")).put("view", loaded))).toString()
        ui.runOnIdle {
            bridge.applySnapshot(reply).takeIf { it.isNotEmpty() }?.let(filter::applyJson)
            bridge.resolveEffect(eff.getLong("id"), true, reply).takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        }
        ui.onNodeWithTag("view.cell.table.object-999.user.property/Column23").assertIsDisplayed()
        ui.onNodeWithTag("button.overflow-menu").performClick()
        ui.onNodeWithTag("button.page.tag-properties").performClick()
        ui.onNodeWithTag("property.schema.owner.user.property/Notes", useUnmergedTree = true).assertIsDisplayed()
        ui.onNodeWithTag("property.add.owner").assertDoesNotExist()
    }

    private fun resultPageFillsRemainingHeight(isTag: Boolean, type: String) {
        val response = snapshot()
        val columns = JSONArray().put(JSONObject().put("attr", "block/title").put("title", "Name"))
        response.getJSONObject("result").put("selectedPageIsTag", isTag).put("selectedPageIsProperty", !isTag)
            .put("outlinerRows", JSONArray()).remove("nodeProperties")
        response.getJSONObject("result").put("resultViews", JSONObject().put("ownerUuid", "owner")
            .put("featureType", if (isTag) "class-objects" else "property-objects")
            .put("views", JSONArray().put(JSONObject().put("uuid", "results").put("name", "All").put("type", type)
                .put("columns", columns).put("rowCount", 1000).put("rowOffset", 0).put("rowsDeferred", true)
                .put("input", "").put("revision", 1).put("rows", JSONArray().apply {
                    repeat(12) { put(JSONObject().put("block", JSONObject().put("uuid", "object-$it")
                        .put("title", "Object $it").put("pageId", "owner"))) }
                }))))
        val height = mutableStateOf(440.dp)
        render(response = response, height = height)
        val identifier = when (type) { "table" -> "view.table.viewport.results"; "gallery" -> "view.gallery.results"; else -> "query.rows.owner" }
        val before = ui.onNodeWithTag(identifier).fetchSemanticsNode().boundsInRoot.height
        ui.runOnIdle { height.value = 600.dp }
        val after = ui.onNodeWithTag(identifier).fetchSemanticsNode().boundsInRoot.height
        val growth = with(ui.density) { 160.dp.toPx() }
        assertEquals("$isTag $type fills additional available height", growth, after - before, 3f)
    }

    @Test fun tagTableFillsRemainingHeight() = resultPageFillsRemainingHeight(true, "table")
    @Test fun tagListFillsRemainingHeight() = resultPageFillsRemainingHeight(true, "list")
    @Test fun tagGalleryFillsRemainingHeight() = resultPageFillsRemainingHeight(true, "gallery")
    @Test fun propertyTableFillsRemainingHeight() = resultPageFillsRemainingHeight(false, "table")
    @Test fun propertyListFillsRemainingHeight() = resultPageFillsRemainingHeight(false, "list")
    @Test fun propertyGalleryFillsRemainingHeight() = resultPageFillsRemainingHeight(false, "gallery")

    @Test fun existingBlockTagsOfferRemovalAndTagPropertiesUseTheirOwnSheet() {
        render()
        ui.onNodeWithTag("property.tag.owner.tag-0").assertDoesNotExist()
        ui.onNodeWithTag("button.block-tag.tag-0").performTouchInput { longClick() }
        ui.onNodeWithTag("button.block-tag.remove.body.tag-0").assertIsDisplayed().performClick()
        val removal = JSONObject(effects().single { it.optString("kind") == "node-property" }.getString("text"))
        assertEquals("body", removal.getString("blockUuid"))
        assertEquals("removeTag", removal.getString("action"))
        ui.onNodeWithTag("property.schema.owner.user.property/Notes").assertDoesNotExist()
        ui.onNodeWithTag("button.overflow-menu").performClick()
        ui.onNodeWithTag("button.page.tag-properties").performClick()
        ui.onNodeWithTag("property.schema.owner.user.property/Notes", useUnmergedTree = true).assertIsDisplayed()
        ui.onNodeWithTag("property.add.owner").performClick()
        ui.onNodeWithTag("property.add.option.owner.user.property/Summary").assertIsDisplayed()
        ui.onNodeWithTag("property.add.owner.cancel").performClick()
        ui.onNodeWithTag("property.schema.actions.owner.user.property/Notes").performClick()
        ui.onNodeWithTag("property.schema.remove.owner.user.property/Notes").assertIsDisplayed().performClick()
        val schemaRemoval = JSONObject(effects().single { it.optString("kind") == "node-property" }.getString("text"))
        assertEquals("owner", schemaRemoval.getString("blockUuid"))
        assertEquals("remove", schemaRemoval.getString("action"))
    }

    @Test fun setTagsSearchesTheWholeCatalogAndSavesDeselection() {
        render()
        ui.onNodeWithTag("button.overflow-menu").performClick()
        ui.onNodeWithTag("button.page.tags").performClick()
        val editor = "page.tags.owner"
        ui.onNodeWithTag("view.edit.option.$editor.tag-499").assertDoesNotExist()
        ui.onNodeWithTag("view.edit.option.$editor.tag-0").performClick()
        ui.onNodeWithTag("view.edit.value.$editor").performTextReplacement("PerfTag499")
        ui.onNodeWithTag("view.edit.option.$editor.tag-499").assertIsDisplayed().performClick()
        ui.onNodeWithTag("view.edit.save.$editor").performClick()
        val selected = JSONObject(effects().single { it.optString("kind") == "node-property" }.getString("text"))
        assertEquals("setTags", selected.getString("action"))
        assertEquals(listOf("tag-499"), selected.getJSONArray("selectedValues").let { array ->
            (0 until array.length()).map(array::getString)
        })
    }

    @Test fun searchCountsUnicodeCodePointsAndClosesWithoutAnEmptyQueryRequest() {
        render(language = "zh-CN")
        effects()
        ui.onNodeWithTag("button.search").performClick()
        ui.onNodeWithContentDescription("关闭").assertIsDisplayed()
        for (query in listOf("ab", "中文", "😀😀")) {
            ui.onNodeWithTag("field.search").performTextReplacement(query)
            assertTrue("Two code points must not search", effects().none { it.optString("kind") == "search-nodes" })
        }
        ui.onNodeWithTag("field.search").performTextReplacement("中😀文")
        var searches = emptyList<JSONObject>()
        ui.waitUntil(5000) {
            searches = effects().filter { it.optString("kind") == "search-nodes" }
            searches.isNotEmpty()
        }
        assertEquals("中😀文", searches.single().getString("text"))
        ui.onNodeWithTag("button.search.close").performClick()
        ui.onNodeWithTag("field.search").assertDoesNotExist()
        assertTrue(effects().none { it.optString("kind") == "search-nodes" && it.optString("text").isEmpty() })
    }
}
