package com.logseq.app

import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextRange
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class AndroidEditorKeyboardTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()

    private fun render(title: String): SemanticsNodeInteraction {
        val registry = logseqExtensionRegistry { it }
        val backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val ops = JSONArray().put(JSONObject().put("op", "create-node").put("id", 1).put("kind", "root"))
            .put(JSONObject().put("op", "create-extension").put("id", 2).put("identifier", "outliner-editor")
                .put("fingerprint", registry.registration("outliner-editor")!!.fingerprint))
            .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 2).put("index", 0))
        mapOf("block-id" to "keyboard-block", "title" to title, "caret-utf16-offset" to title.length,
            "selection-revision" to 0, "input-policy" to "{}").forEach { (name, value) ->
            ops.put(JSONObject().put("op", "set-extension-prop").put("id", 2).put("property", name).put("value", value))
        }
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))
        ui.setContent { MaterialExpressiveTheme { backend.Content(1) } }
        return ui.onNodeWithTag("field.outliner.block.keyboard-block").assertIsFocused()
    }

    @Test fun shiftEnterInsertsANewlineWithoutSplittingTheBlock() {
        val editor = render("Draft 中文 📝")
        editor.performKeyInput { keyDown(Key.ShiftLeft); pressKey(Key.Enter); keyUp(Key.ShiftLeft) }
        editor.assertTextEquals("Draft 中文 📝\n")
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any { it.name == "text-change" } }
        ui.runOnIdle { assertFalse(events.filterIsInstance<LuiEvent.Extension>().any { it.name == "return" }) }
    }

    @Test fun shiftEnterReplacesAReversedUnicodeSelectionAtTheCorrectCaret() {
        val editor = render("Hello 中文 📝 world")
        editor.performTextInputSelection(TextRange(11, 6))
        editor.performKeyInput { keyDown(Key.ShiftRight); pressKey(Key.Enter); keyUp(Key.ShiftRight) }
        editor.assertTextEquals("Hello \n world")
        editor.performTextInput("Next")
        editor.assertTextEquals("Hello \nNext world")
        ui.runOnIdle { assertFalse(events.filterIsInstance<LuiEvent.Extension>().any { it.name == "return" }) }
    }

    @Test fun ordinaryEnterStillSplitsAndPastedMultilineTextStaysInOneBlock() {
        val editor = render("Draft")
        editor.performTextInput(" multiple\nlines")
        editor.assertTextEquals("Draft multiple\nlines")
        editor.performKeyInput { pressKey(Key.Enter) }
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any { it.name == "return" } }
        ui.runOnIdle { assertEquals(1, events.filterIsInstance<LuiEvent.Extension>().count { it.name == "return" }) }
    }
}
