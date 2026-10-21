package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiPatchOp
import dev.lui.LuiBackend
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidOutlinerParityTest {
    @get:Rule val ui = createComposeRule()

    @Test fun tenThousandNestedBlocksScrollUpdateTheTitleAndRetainPositionOnBack() {
        lateinit var bridge: LogseqNativeBridge
        val liveRows = mutableMapOf<Long, String>()
        val backend = LuiBackend(
            onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it },
            icons = logseqIconResolver,
        )
        val filter = LuiPatchFilter(backend)
        fun applyPatch(patch: String) {
            for (operation in filter.applyJson(patch).ops) {
                if (operation is LuiPatchOp.DropNode) liveRows.remove(operation.id)
                if (operation is LuiPatchOp.SetProp && operation.property == "accessibility-identifier" &&
                    operation.value.stringValue?.startsWith("outliner.block.") == true) {
                    liveRows[operation.id] = operation.value.stringValue!!
                }
            }
            liveRows.keys.removeAll { backend.nodeKind(it) == null }
        }
        bridge = LogseqNativeBridge(onPatch = ::applyPatch)
        val root = bridge.initialize(authenticationCode = 3)
        val rows = JSONArray()
        repeat(10_000) { index ->
            val firstDay = index < 5_000
            rows.put(JSONObject().put("depth", index % 4).put("hasChildren", index % 4 < 3)
                .put("block", JSONObject().put("uuid", "android-$index").put("title", "Block $index")
                    .put("pageId", if (firstDay) "first-journal" else "second-journal")
                    .put("journalTitle", if (firstDay) "Oct 19th, 2026" else "Oct 18th, 2026")
                    .put("journalDay", if (firstDay) 20261019 else 20261018)))
        }
        applyPatch(bridge.applySnapshot(JSONObject().put("ok", true).put("result", JSONObject()
            .put("graphName", "Android UI test").put("selectedGraphId", "android-ui-test")
            .put("isGraphUnlocked", true).put("outlinerRows", rows)).toString()))
        ui.setContent {
            MaterialTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                CompositionLocalProvider(dev.lui.LocalLuiThemeDark provides false) {
                    Box(Modifier.fillMaxSize()) { backend.Content(root) }
                }
            }
        }
        try {
            ui.onNodeWithText("Block 0").assertIsDisplayed()
            ui.runOnIdle { assertTrue("Only the viewport owns native protocol rows", liveRows.size <= 32) }
            ui.onNodeWithTag("list.outliner").performScrollToIndex(9_990)
            ui.waitForIdle()
            ui.onNodeWithText("Block 9990").assertIsDisplayed()
            ui.onNodeWithTag("title.main").assertTextEquals("Oct 18th, 2026")
            ui.runOnIdle { assertTrue(liveRows.size <= 32) }
            val before = ui.onNodeWithText("Block 9990").fetchSemanticsNode().boundsInRoot.top
            ui.onNodeWithTag("button.outliner.zoom.android-9990.Block 9990").performClick()
            ui.onNodeWithTag("button.navigation.back").performClick()
            ui.onNodeWithText("Block 9990").assertIsDisplayed()
            val after = ui.onNodeWithText("Block 9990").fetchSemanticsNode().boundsInRoot.top
            assertEquals("Back restores the original viewport", before, after, 1f)
            ui.onNodeWithTag("button.search").performClick()
            ui.onNodeWithTag("field.search").assertIsFocused()
            ui.onNodeWithTag("header.main").assertDoesNotExist()
            ui.onNodeWithText("Block 9990").assertIsNotDisplayed()
            ui.onNodeWithContentDescription("Close search").performClick()
            ui.onNodeWithText("Block 9990").assertIsDisplayed()
            ui.onNodeWithTag("button.composer.expand").performClick()
            ui.onNodeWithTag("field.composer").assertIsFocused().assertHeightIsAtLeast(56.dp)
        } finally {
            ui.runOnIdle { bridge.close() }
        }
    }
}
