package com.logseq.app

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
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

    private fun render(language: String = "en") {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        filter.applyJson(bridge.applySnapshot(snapshot().toString()))
        bridge.applyHostUpdate("settings", """{"appearance":"light","language":"$language","systemLanguage":"en","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"https://api.logseq.io","version":"test","revision":"test"}""")
            .takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Surface(Modifier.fillMaxSize(), color = LogseqTheme.lightScheme.background) { backend.Content(root) }
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
