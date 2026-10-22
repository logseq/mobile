package com.logseq.app

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
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

    private fun mount() {
        backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        val snapshot = InstrumentationRegistry.getInstrumentation().context.assets
            .open("query-result-views.json").bufferedReader().use { it.readText() }
        filter.applyJson(bridge.applySnapshot(snapshot))
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

    private fun assertFullTabLabel(text: String) {
        val layouts = mutableListOf<TextLayoutResult>()
        ui.onNodeWithText(text, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue("The selected native tab must show its full label",
            layouts.isNotEmpty() && layouts.none { it.isLineEllipsized(0) })
    }

    private fun selectView(name: String) {
        val tabs = ui.onNodeWithTag("view.tabs.query-owner")
        val target = ui.onNodeWithTag("view.tab.$name")
        repeat(4) {
            val viewport = tabs.getUnclippedBoundsInRoot()
            val bounds = target.getUnclippedBoundsInRoot()
            val center = (bounds.left.value + bounds.right.value) / 2
            if (center > viewport.left.value && center < viewport.right.value) {
                target.performClick()
                return
            }
            tabs.performTouchInput {
                if (center < viewport.left.value) swipeRight() else swipeLeft()
            }
        }
        error("The saved view tab must be reachable by swiping")
    }

    @Test fun savedListsGallerySearchAndErrorsRenderInCompose() {
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
        ui.onNodeWithTag("view.error.broken").assertIsDisplayed()
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
        assertFullTabLabel("Table")
        ui.onNodeWithTag("view.table.scroll.table").assertIsDisplayed()
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
        ui.onNodeWithTag("view.filter.add.table").performClick()
        capture("settings")
        ui.onNodeWithTag("view.settings.cancel.table").performClick()
        selectView("list")
        ui.onNodeWithText("Project result 1").assertIsDisplayed()
        ui.runOnIdle { assertNull(backend.lastError) }
    }
}
