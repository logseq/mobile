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
    private lateinit var backend: LuiBackend
    private var generation = 1

    private fun render(title: String, inputPolicy: String = "{}"): SemanticsNodeInteraction {
        val registry = logseqExtensionRegistry { it }
        backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val ops = JSONArray().put(JSONObject().put("op", "create-node").put("id", 1).put("kind", "root"))
            .put(JSONObject().put("op", "create-extension").put("id", 2).put("identifier", "outliner-editor")
                .put("fingerprint", registry.registration("outliner-editor")!!.fingerprint))
            .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 2).put("index", 0))
        mapOf("block-id" to "keyboard-block", "title" to title, "caret-utf16-offset" to title.length,
            "selection-revision" to 0, "focus-enabled" to true, "input-policy" to inputPolicy).forEach { (name, value) ->
            ops.put(JSONObject().put("op", "set-extension-prop").put("id", 2).put("property", name).put("value", value))
        }
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))
        ui.setContent { MaterialExpressiveTheme { backend.Content(1) } }
        return ui.onNodeWithTag("field.outliner.block.keyboard-block").assertIsFocused()
    }

    private fun acknowledge(block: String, title: String, caret: Int) {
        ui.runOnIdle {
            val ops = JSONArray()
            mapOf("block-id" to block, "title" to title, "caret-utf16-offset" to caret).forEach { (name, value) ->
                ops.put(JSONObject().put("op", "set-extension-prop").put("id", 2).put("property", name).put("value", value))
            }
            assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", ++generation).put("ops", ops).toString()))
        }
    }

    @Test fun codeEditingHighlightsDefinitionsAndPreservesSelectionAndInput() {
        val source = "(def answer 42)\n(defn square [x] (* x x))"
        val field = render(source, """{"multiline":true,"code":true,"language":"clojure"}""")
        fun layout(): androidx.compose.ui.text.TextLayoutResult {
            val values = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            field.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(values) }
            return values.single()
        }
        ui.waitUntil(5_000) { layout().layoutInput.text.spanStyles.isNotEmpty() }
        assertEquals(source, layout().layoutInput.text.text)
        field.performTextInputSelection(TextRange(5, 11))
        field.performTextInput("value")
        ui.waitUntil(5_000) { layout().layoutInput.text.text.contains("(def value 42)") }
        assertTrue(layout().layoutInput.text.spanStyles.any { it.start == 1 && it.end == 4 })
    }

    @Test fun splitKeepsTextUntilTheEditorMovesToTheNewBlock() {
        val editor = render("Hello 中文 📝")
        editor.performTextInputSelection(TextRange(6))
        editor.performKeyInput { pressKey(Key.Enter) }
        acknowledge("keyboard-block", "Hello ", 6)
        editor.assertTextEquals("Hello 中文 📝")
        acknowledge("next-block", "中文 📝", 0)
        ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("中文 📝")
    }

    @Test fun typingDuringSplitIsMergedAtTheNewCaretAndPublishedForTheNewBlock() {
        val editor = render("Hello 中文 📝")
        editor.performTextInputSelection(TextRange(6))
        editor.performKeyInput { pressKey(Key.Enter) }
        editor.performTextInput("新📝")
        acknowledge("keyboard-block", "Hello ", 6)
        acknowledge("next-block", "中文 📝", 0)
        ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("新📝中文 📝")
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any {
            it.name == "text-change" && it.values["title"] == "新📝中文 📝"
        } }
    }

    @Test fun rapidEnterAndUnicodeTypingKeepTheirOrderAcrossTwoHandoffs() {
        val editor = render("Tail")
        editor.performTextInputSelection(TextRange(0))
        editor.performKeyInput { pressKey(Key.Enter) }
        editor.performTextInput("first")
        editor.performKeyInput { pressKey(Key.Enter) }
        editor.performTextInput("后📝")
        acknowledge("next-one", "Tail", 0)
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().count { it.name == "return" } >= 2 }
        ui.runOnIdle {
            val returns = events.filterIsInstance<LuiEvent.Extension>().filter { it.name == "return" }
            assertEquals("firstTail", returns.last().values["title"])
            assertEquals(5, returns.last().values["caret-utf16-offset"])
        }
        acknowledge("next-two", "Tail", 0)
        ui.onNodeWithTag("field.outliner.block.next-two").assertIsFocused().assertTextEquals("后📝Tail")
    }

    @Test fun repeatedEnterDuringHandoffIsNeverDebouncedIntoATextChange() {
        val editor = render("Draft")
        repeat(3) { editor.performKeyInput { pressKey(Key.Enter) } }
        acknowledge("second", "", 0)
        acknowledge("third", "", 0)
        ui.runOnIdle { assertEquals(3, events.filterIsInstance<LuiEvent.Extension>().count { it.name == "return" }) }
    }

    @Test fun splitAppliesTheNewEditorTextAndIdentityInOneFrame() {
        val editor = render("Original text")
        editor.performTextInputSelection(TextRange(0))
        editor.performKeyInput { pressKey(Key.Enter) }
        ui.mainClock.autoAdvance = false
        try {
            ui.runOnUiThread {
                val ops = JSONArray()
                mapOf("block-id" to "next-block", "title" to "Retained text", "caret-utf16-offset" to 0).forEach { (name, value) ->
                    ops.put(JSONObject().put("op", "set-extension-prop").put("id", 2).put("property", name).put("value", value))
                }
                assertTrue(backend.applyJson(JSONObject().put("generation", ++generation).put("ops", ops).toString()))
            }
            ui.mainClock.advanceTimeByFrame()
            ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("Retained text")
        } finally { ui.mainClock.autoAdvance = true }
    }

    @Test fun softwareKeyboardNextCreatesOneBlockWithoutCommittingANewline() {
        val editor = render("Native keyboard")
        assertEquals(android.view.inputmethod.EditorInfo.IME_ACTION_NEXT,
            editorInfo().imeOptions and android.view.inputmethod.EditorInfo.IME_MASK_ACTION)
        editor.performImeAction()
        editor.assertTextEquals("Native keyboard")
        ui.runOnIdle { assertEquals(1, events.filterIsInstance<LuiEvent.Extension>().count { it.name == "return" }) }
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
    @Test fun codeEnterInsertsLinesAndShiftEnterCreatesOneBlock() {
        val editor = render("6*7", """{"code":true,"multiline":true}""")
        editor.performKeyInput { pressKey(Key.Enter) }
        editor.assertTextEquals("6*7\n")
        editor.performTextInput("last*3\n")
        editor.assertTextEquals("6*7\nlast*3\n")
        ui.runOnIdle { assertFalse(events.filterIsInstance<LuiEvent.Extension>().any { it.name == "return" }) }
        editor.performKeyInput { keyDown(Key.ShiftLeft); pressKey(Key.Enter); keyUp(Key.ShiftLeft) }
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any { it.name == "return" } }
        ui.runOnIdle { assertEquals(1, events.filterIsInstance<LuiEvent.Extension>().count { it.name == "return" }) }
    }

    @Test fun codeShiftEnterReplacesUnicodeSelectionAndPreservesHandoffTyping() {
        val editor = render("Hello 中文 📝 world", """{"code":true,"multiline":true}""")
        editor.performTextInputSelection(TextRange(11, 6))
        editor.performKeyInput { keyDown(Key.ShiftRight); pressKey(Key.Enter); keyUp(Key.ShiftRight) }
        ui.runOnIdle {
            val split = events.filterIsInstance<LuiEvent.Extension>().single { it.name == "return" }
            assertEquals("Hello  world", split.values["title"])
            assertEquals(6, split.values["caret-utf16-offset"])
        }
        editor.performTextInput("Next")
        acknowledge("next-block", " world", 0)
        ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("Next world")
    }

    @Test fun savedWritingAssistanceFlagsReachTheNativeKeyboardAndUpdateWithoutLosingSelection() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("logseq", android.content.Context.MODE_PRIVATE)
        val before = preferences.all
        try {
            preferences.edit().putBoolean("logseq.editor.autoCorrection", false)
                .putBoolean("logseq.editor.spellCheck", true).commit()
            val editor = render("Hello 中文")
            editor.performTextInputSelection(TextRange(6, 8))
            assertEquals(0, editorInfo().inputType and android.text.InputType.TYPE_TEXT_FLAG_AUTO_CORRECT)
            assertEquals(0, editorInfo().inputType and android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
            ui.runOnIdle {
                preferences.edit().putBoolean("logseq.editor.autoCorrection", true)
                    .putBoolean("logseq.editor.spellCheck", false).commit()
            }
            ui.waitForIdle()
            assertTrue(editorInfo().inputType and android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0)
            editor.assertTextEquals("Hello 中文")
            editor.performTextInput("world")
            editor.assertTextEquals("Hello world")
        } finally {
            preferences.edit().apply {
                listOf("logseq.editor.autoCorrection", "logseq.editor.spellCheck").forEach { key ->
                    if (before.containsKey(key)) putBoolean(key, before[key] as Boolean) else remove(key)
                }
            }.commit()
        }
    }

    @Test fun enabledWritingAssistancePreservesMultilineAndSentenceCapitalization() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("logseq", android.content.Context.MODE_PRIVATE)
        val before = preferences.all
        try {
            preferences.edit().putBoolean("logseq.editor.autoCorrection", true)
                .putBoolean("logseq.editor.spellCheck", true).commit()
            render("Draft")
            val type = editorInfo().inputType
            assertTrue(type and android.text.InputType.TYPE_TEXT_FLAG_AUTO_CORRECT != 0)
            assertTrue(type and android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0)
            assertTrue(type and android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES != 0)
            assertEquals(0, type and android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        } finally {
            preferences.edit().apply {
                listOf("logseq.editor.autoCorrection", "logseq.editor.spellCheck").forEach { key ->
                    if (before.containsKey(key)) putBoolean(key, before[key] as Boolean) else remove(key)
                }
            }.commit()
        }
    }

    private fun editorInfo(): android.view.inputmethod.EditorInfo {
        var info: android.view.inputmethod.EditorInfo? = null
        fun find(view: android.view.View) {
            if (view.onCheckIsTextEditor()) {
                val attributes = android.view.inputmethod.EditorInfo()
                if (view.onCreateInputConnection(attributes) != null) info = attributes
            }
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index))
        }
        ui.runOnIdle { android.view.inspector.WindowInspector.getGlobalWindowViews().forEach(::find) }
        return requireNotNull(info) { "No native editor connection" }
    }

}
