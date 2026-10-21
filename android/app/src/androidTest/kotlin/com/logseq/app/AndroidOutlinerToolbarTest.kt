package com.logseq.app

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidOutlinerToolbarTest {
    @get:Rule val ui = createComposeRule()
    private var bridge: LogseqNativeBridge? = null
    private lateinit var filter: LuiPatchFilter
    private val events = mutableListOf<LuiEvent>()
    private val title = "Draft 中文 📝 note"

    @After fun closeBridge() { bridge?.let { ui.runOnIdle { it.close() } } }

    private fun snapshot(editing: Boolean, caret: Int = title.length): String {
        val state = if (editing) JSONObject().put("editing", JSONObject().put("uuid", "toolbar-block")
            .put("title", title).put("caretUTF16Offset", caret))
        else JSONObject().put("selectedBlockIds", org.json.JSONArray().put("toolbar-block"))
        return JSONObject().put("ok", true).put("result", JSONObject()
            .put("graphName", "Toolbar test").put("selectedGraphId", "toolbar-test")
            .put("isGraphUnlocked", true).put("outlinerState", state)
            .put("outlinerRows", org.json.JSONArray().put(JSONObject().put("depth", 0)
                .put("hasChildren", false).put("block", JSONObject().put("uuid", "toolbar-block")
                    .put("title", title).put("pageId", "toolbar-journal")
                    .put("journalTitle", "Oct 22nd, 2026").put("journalDay", 20261022))))).toString()
    }

    private fun toolbar(editing: Boolean = true) {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(onEvent = {
            events.add(it)
            dispatchLuiEvent(it, native)
        }, extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
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

    @Test fun editorUsesTheNativeFloatingToolbarContainer() {
        toolbar()
        ui.onNodeWithTag("toolbar.outliner.editor").assertHeightIsAtLeast(64.dp)
        ui.onNodeWithTag("field.outliner.block.toolbar-block").assertIsFocused()
        capture("editor-toolbar")
    }

    @Test fun blockSelectionUsesTheNativeFloatingToolbarContainer() {
        toolbar(editing = false)
        ui.onNodeWithTag("toolbar.outliner.selection").assertHeightIsAtLeast(64.dp)
        capture("selection-toolbar")
    }

    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureToolbar") != "true") return
        val directory = requireNotNull(InstrumentationRegistry.getInstrumentation()
            .targetContext.getExternalFilesDir("qa"))
        directory.mkdirs()
        directory.resolve("m3-$name.png").outputStream().use {
            ui.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun editorOverflowKeepsHideKeyboardReachableAndEmitsOneAction() {
        toolbar()
        val hide = ui.onNodeWithTag("button.outliner.editor.hideKeyboard")
        hide.assertIsDisplayed()
        val before = hide.fetchSemanticsNode().boundsInRoot
        val reference = ui.onNodeWithTag("button.outliner.editor.pageReference")
        repeat(2) {
            ui.onNodeWithTag("toolbar.outliner.editor").performTouchInput {
                swipeLeft(startX = width * 0.7f, endX = width * 0.15f, durationMillis = 400)
            }
        }
        capture("editor-overflow")
        reference.assertIsDisplayed()
        assertEquals(before, hide.fetchSemanticsNode().boundsInRoot)
        ui.runOnIdle { events.clear() }
        hide.performClick()
        ui.runOnIdle {
            assertEquals(1, events.filterIsInstance<LuiEvent.Press>().size)
            assertEquals(listOf("hideKeyboard"), pendingToolbarActions())
        }
    }

    @Test fun selectionOverflowKeepsUnselectReachableAndEmitsOneAction() {
        toolbar(editing = false)
        val unselect = ui.onNodeWithTag("button.outliner.selection.unselect")
        unselect.assertIsDisplayed()
        val before = unselect.fetchSemanticsNode().boundsInRoot
        ui.onNodeWithTag("toolbar.outliner.selection").performTouchInput {
            swipeLeft(startX = width * 0.7f, endX = width * 0.15f, durationMillis = 400)
        }
        ui.onNodeWithTag("button.outliner.selection.copyURL").assertIsDisplayed()
        assertEquals(before, unselect.fetchSemanticsNode().boundsInRoot)
        ui.runOnIdle { events.clear() }
        unselect.performClick()
        ui.runOnIdle {
            assertEquals(1, events.filterIsInstance<LuiEvent.Press>().size)
            assertEquals(listOf("unselect"), pendingToolbarActions())
        }
    }

    private fun pendingToolbarActions(): List<String> = buildList {
        repeat(32) {
            val encoded = requireNotNull(bridge).takeEffect()
            if (encoded.isEmpty()) return@buildList
            val effect = JSONObject(encoded).optJSONObject("effect") ?: return@buildList
            if (effect.optString("kind") == "outliner-toolbar") add(effect.getString("text"))
        }
        error("Native effect queue did not drain")
    }

    @Test fun aNativeTextSelectionSurvivesTheSharedCaretAcknowledgement() {
        toolbar()
        val editor = ui.onNodeWithTag("field.outliner.block.toolbar-block")
        editor.performTextInputSelection(TextRange(6, 11))
        editor.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(6, 11)))
    }

    @Test fun aReversedNativeSelectionSurvivesTheSharedCaretAcknowledgement() {
        toolbar()
        val editor = ui.onNodeWithTag("field.outliner.block.toolbar-block")
        editor.performTextInputSelection(TextRange(11, 6))
        editor.assert(SemanticsMatcher("The chosen text remains selected after native normalization") {
            val range = it.config[SemanticsProperties.TextSelectionRange]
            range.min == 6 && range.max == 11
        })
    }

    @Test fun anExternalCaretRequestStillUpdatesTheNativeEditor() {
        toolbar()
        val editor = ui.onNodeWithTag("field.outliner.block.toolbar-block")
        editor.performTextInputSelection(TextRange(6, 11))
        ui.runOnIdle { filter.applyJson(requireNotNull(bridge).applySnapshot(snapshot(true, caret = 1))) }
        editor.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(1)))
    }
}
