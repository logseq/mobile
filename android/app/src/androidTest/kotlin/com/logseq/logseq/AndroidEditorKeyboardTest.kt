package com.logseq.logseq

import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.view.KeyEvent as AndroidKeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inspector.WindowInspector
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

class AndroidEditorKeyboardTest {
    @get:Rule val ui = createAndroidComposeRule<ComponentActivity>()
    private val events = mutableListOf<LuiEvent>()
    private lateinit var backend: LuiBackend
    private var generation = 1

    @Before fun isolateSystemInputMethod() {
        ui.activityRule.scenario.onActivity { activity ->
            // These tests drive the editor's input connection directly. A system IME can send
            // asynchronous composition updates to the same field between test commands.
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        }
    }

    private fun render(title: String, inputPolicy: String = "{}",
        importPastedImage: (suspend (Uri) -> JSONObject)? = null): SemanticsNodeInteraction {
        val registry = logseqExtensionRegistry(importPastedImage = importPastedImage)
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

    @Test fun pasteFromImageClipboardHandsTheEditorAnAsset() {
        val file = File.createTempFile("image-paste", ".png", ui.activity.cacheDir)
        val image = Bitmap.createBitmap(2, 3, Bitmap.Config.ARGB_8888)
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
        try {
            val editor = render("") { uri ->
                val bytes = ui.activity.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                assertArrayEquals(file.readBytes(), bytes)
                JSONObject().put("localPath", file.path).put("assetType", "png")
            }
            ui.runOnIdle {
                val platform = AndroidPlatformServices(ui.activity)
                platform.copyImages(listOf(file.path), replacing = platform.clipboardTimestamp())
            }
            editor.performKeyInput {
                keyDown(Key.CtrlLeft)
                pressKey(Key.V)
                keyUp(Key.CtrlLeft)
            }
            ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any { it.name == "paste-content" } }
            ui.runOnIdle {
                val event = events.filterIsInstance<LuiEvent.Extension>().single { it.name == "paste-content" }
                val payload = JSONObject(event.values["value"] as String)
                assertEquals("", payload.getString("beforeTitle"))
                assertEquals("png", payload.getJSONArray("assets").getJSONObject(0).getString("assetType"))
            }
        } finally {
            file.delete()
        }
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
        editor.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(6)))
        acknowledge("next-block", "中文 📝", 0)
        ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("中文 📝")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(0)))
    }

    @Test fun typingDuringSplitIsMergedAtTheNewCaretAndPublishedForTheNewBlock() {
        val editor = render("Hello 中文 📝")
        editor.performTextInputSelection(TextRange(6))
        editor.performKeyInput { pressKey(Key.Enter) }
        editor.performTextInput("新📝")
        editor.assertTextEquals("Hello 中文 📝")
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
        pressHardwareEnterWithoutComposition()
        editor.performTextInput("first")
        pressHardwareEnterWithoutComposition()
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
        render("Draft")
        repeat(3) { pressHardwareEnterWithoutComposition() }
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

    @Test fun tappingAnotherBlockAppliesItsTextAndCaretInOneFrame() {
        render("Source block")
        ui.mainClock.autoAdvance = false
        try {
            ui.runOnUiThread {
                val ops = JSONArray()
                mapOf("block-id" to "target-block", "title" to "Target 中文 📝",
                    "caret-utf16-offset" to 7).forEach { (name, value) ->
                    ops.put(JSONObject().put("op", "set-extension-prop").put("id", 2)
                        .put("property", name).put("value", value))
                }
                assertTrue(backend.applyJson(JSONObject().put("generation", ++generation).put("ops", ops).toString()))
            }
            ui.mainClock.advanceTimeByFrame()
            ui.onNodeWithTag("field.outliner.block.target-block").assertIsFocused().assertTextEquals("Target 中文 📝")
                .assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(7)))
        } finally { ui.mainClock.autoAdvance = true }
    }

    @Test fun softwareKeyboardNextCreatesOneBlockWithoutCommittingANewline() {
        val editor = render("")
        assertEquals(EditorInfo.IME_ACTION_NEXT, editorInfo().imeOptions and EditorInfo.IME_MASK_ACTION)
        editor.performTextInput("Native keyboard")
        editor.performImeAction()
        editor.assertTextEquals("Native keyboard")
        editor.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange("Native keyboard".length)))
        ui.runOnIdle { assertEquals(1, events.filterIsInstance<LuiEvent.Extension>().count { it.name == "return" }) }
    }

    @Test fun softwareKeyboardNextHandsOffWhileTheNextWordIsComposing() {
        assertNextBlockKeepsComposition(reopenInBatch = false)
    }

    @Test fun softwareKeyboardNextKeepsCompositionWhenImeFinishesAndReopensItInABatch() {
        assertNextBlockKeepsComposition(reopenInBatch = true)
    }

    @Test fun softwareKeyboardNextFinishesCompositionAtTheEndOfAnImeBatch() {
        val (next, connection) = beginNextBlockComposition()
        ui.runOnIdle {
            assertTrue(connection.beginBatchEdit())
            assertTrue(connection.finishComposingText())
            connection.endBatchEdit()
        }
        next.assertTextEquals("ni")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.TextCompositionRange, null))
    }

    private fun assertNextBlockKeepsComposition(reopenInBatch: Boolean) {
        val (next, typingConnection) = beginNextBlockComposition()
        ui.runOnIdle {
            if (reopenInBatch) {
                assertTrue(typingConnection.beginBatchEdit())
                assertTrue(typingConnection.beginBatchEdit())
                assertTrue(typingConnection.finishComposingText())
                assertTrue(typingConnection.endBatchEdit())
            }
            assertTrue(if (Build.VERSION.SDK_INT >= 33) typingConnection.setComposingRegion(0, "ni".length, null)
                else typingConnection.setComposingRegion(0, "ni".length))
            assertTrue(typingConnection.setComposingText("nih", 1))
            if (reopenInBatch) typingConnection.endBatchEdit()
        }
        next.assertTextEquals("nih")
        ui.runOnIdle { assertTrue(typingConnection.commitText("你", 1)) }
        next.assertIsFocused().assertTextEquals("你")
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any {
            it.name == "text-change" && it.values["title"] == "你"
        } }
    }

    private fun beginNextBlockComposition(): Pair<SemanticsNodeInteraction, InputConnection> {
        val editor = render("")
        val connection = inputConnection()
        ui.runOnIdle { assertTrue(connection.commitText("Hello", 1)) }
        editor.assertTextEquals("Hello")
        ui.runOnIdle { assertTrue(connection.performEditorAction(EditorInfo.IME_ACTION_NEXT)) }
        assertSplit("Hello")
        val typingConnection = inputConnection()
        ui.runOnIdle {
            assertTrue(typingConnection.setComposingRegion(0, "Hello".length))
            assertTrue(typingConnection.setComposingText("ni", 1))
        }
        acknowledge("next-block", "", 0)
        val next = ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("ni")
        return next to typingConnection
    }

    @Test fun softwareKeyboardCanConfirmACandidateInTheCurrentBlock() {
        val editor = render("Draft ")
        val connection = inputConnection()
        ui.runOnIdle {
            assertTrue(connection.setComposingText("nihao", 1))
            assertTrue(connection.commitText("你好", 1))
        }
        assertCommittedInCurrentBlock(editor, "Draft 你好")
    }

    @Test fun softwareKeyboardNextSplitsImmediatelyWithAnActiveComposition() {
        render("")
        val connection = inputConnection()
        ui.runOnIdle {
            assertTrue(connection.setComposingText("Hello", 1))
            connection.beginBatchEdit()
            assertTrue(connection.performEditorAction(EditorInfo.IME_ACTION_NEXT))
            connection.endBatchEdit()
            // Some IMEs reopen composition on the submitted word before the model acknowledges the split.
            assertTrue(connection.setComposingRegion(0, "Hello".length))
        }
        assertSplit("Hello")
        acknowledge("next-block", "", 0)
        val next = ui.onNodeWithTag("field.outliner.block.next-block").assertIsFocused().assertTextEquals("")
        next.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextCompositionRange, null))
        val nextConnection = inputConnection()
        ui.runOnIdle {
            assertTrue(nextConnection.setComposingText("World", 1))
            assertTrue(nextConnection.performEditorAction(EditorInfo.IME_ACTION_NEXT))
            val returns = events.filterIsInstance<LuiEvent.Extension>().filter { it.name == "return" }
            assertEquals(listOf("Hello", "World"), returns.map { it.values["title"] })
        }
    }

    @Test fun hardwareEnterCommitsCompositionBeforeSplitting() {
        val editor = render("")
        ui.runOnIdle {
            val view = requireNotNull(findEditorView())
            val connection = requireNotNull(view.onCreateInputConnection(EditorInfo()))
            assertTrue(connection.setComposingText("日本語", 1))
            assertTrue(view.dispatchKeyEvent(AndroidKeyEvent(AndroidKeyEvent.ACTION_DOWN, AndroidKeyEvent.KEYCODE_ENTER)))
            view.dispatchKeyEvent(AndroidKeyEvent(AndroidKeyEvent.ACTION_UP, AndroidKeyEvent.KEYCODE_ENTER))
        }
        assertCommittedInCurrentBlock(editor, "日本語")
        editor.performKeyInput { pressKey(Key.Enter) }
        assertSplit("日本語")
    }

    @Test fun keyboardNewlineCommitsCompositionBeforeSplitting() {
        val editor = render("Draft ")
        val connection = inputConnection()
        ui.runOnIdle {
            assertTrue(connection.setComposingText("你好", 1))
            assertTrue(connection.commitText("\n", 1))
        }
        assertCommittedInCurrentBlock(editor, "Draft 你好")
        val nextConnection = inputConnection()
        ui.runOnIdle {
            assertTrue(if (Build.VERSION.SDK_INT >= 33) nextConnection.commitText("\n", 1, null)
                else nextConnection.commitText("\n", 1))
        }
        assertSplit("Draft 你好")
    }

    @Test fun softwareBackspaceOnAnEmptyBlockRequestsOneStructuralDelete() {
        render("")
        val connection = inputConnection()
        ui.runOnIdle {
            connection.beginBatchEdit()
            assertTrue(connection.setSelection(0, 0))
            assertTrue(connection.deleteSurroundingText(1, 0))
            assertTrue(connection.setSelection(0, 0))
            assertTrue(backspaceEvents().isEmpty())
            connection.endBatchEdit()
            val backspace = backspaceEvents().single()
            assertEquals("", backspace.values["title"])
            assertEquals(0, backspace.values["selection-length"])
        }
    }

    @Test fun softwareBackspaceInCodePointsDeletesTextBeforeRemovingTheEmptyBlock() {
        val editor = render("🙂")
        val connection = inputConnection()
        ui.runOnIdle {
            connection.beginBatchEdit()
            assertTrue(connection.deleteSurroundingTextInCodePoints(1, 0))
            connection.endBatchEdit()
        }
        editor.assertTextEquals("")
        ui.runOnIdle {
            assertTrue(backspaceEvents().isEmpty())
            assertTrue(connection.deleteSurroundingTextInCodePoints(1, 0))
            assertEquals(1, backspaceEvents().size)
        }
    }

    @Test fun repeatedSoftwareBackspaceInOneImeBatchRemovesTheEmptyBlock() {
        val editor = render("🙂")
        val connection = inputConnection()
        ui.runOnIdle {
            connection.beginBatchEdit()
            connection.beginBatchEdit()
            assertTrue(connection.deleteSurroundingTextInCodePoints(1, 0))
            assertTrue(connection.setSelection(0, 0))
            assertTrue(connection.deleteSurroundingText(1, 0))
            connection.endBatchEdit()
            assertTrue(backspaceEvents().isEmpty())
            connection.endBatchEdit()
            assertEquals("", backspaceEvents().single().values["title"])
        }
        editor.assertTextEquals("")
    }

    @Test fun movingTheCaretDuringAnImeBatchKeepsTheBlock() {
        val editor = render("a")
        val connection = inputConnection()
        ui.runOnIdle {
            connection.beginBatchEdit()
            assertTrue(connection.setSelection(0, 0))
            assertTrue(connection.deleteSurroundingText(1, 0))
            assertTrue(connection.setSelection(1, 1))
            assertTrue(connection.deleteSurroundingText(1, 0))
            connection.endBatchEdit()
            assertTrue(backspaceEvents().isEmpty())
        }
        editor.assertTextEquals("")
    }

    @Test fun deletingNewTextInTheSameImeBatchKeepsTheBlock() {
        val editor = render("")
        val connection = inputConnection()
        ui.runOnIdle {
            connection.beginBatchEdit()
            assertTrue(connection.commitText("x", 1))
            assertTrue(connection.deleteSurroundingText(1, 0))
            connection.endBatchEdit()
            assertTrue(backspaceEvents().isEmpty())
        }
        editor.assertTextEquals("")
    }

    private fun backspaceEvents() = events.filterIsInstance<LuiEvent.Extension>().filter { it.name == "backspace" }

    private fun assertCommittedInCurrentBlock(editor: SemanticsNodeInteraction, title: String) {
        editor.assertIsFocused().assertTextEquals(title)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(title.length)))
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.TextCompositionRange, null))
        ui.runOnIdle { assertFalse(events.filterIsInstance<LuiEvent.Extension>().any { it.name == "return" }) }
        ui.waitUntil(5_000) { events.filterIsInstance<LuiEvent.Extension>().any {
            it.name == "text-change" && it.values["title"] == title
        } }
    }

    private fun assertSplit(title: String) {
        ui.runOnIdle {
            val split = events.filterIsInstance<LuiEvent.Extension>().single { it.name == "return" }
            assertEquals(title, split.values["title"])
            assertEquals(title.length, split.values["caret-utf16-offset"])
        }
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
        pressHardwareEnterWithoutComposition()
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

    private fun editorInfo() = EditorInfo().also { inputConnection(it) }

    private fun pressHardwareEnterWithoutComposition() {
        ui.runOnIdle {
            val view = requireNotNull(findEditorView())
            val connection = requireNotNull(view.onCreateInputConnection(EditorInfo()))
            assertTrue(connection.finishComposingText())
            assertTrue(view.dispatchKeyEvent(AndroidKeyEvent(AndroidKeyEvent.ACTION_DOWN, AndroidKeyEvent.KEYCODE_ENTER)))
            view.dispatchKeyEvent(AndroidKeyEvent(AndroidKeyEvent.ACTION_UP, AndroidKeyEvent.KEYCODE_ENTER))
        }
    }

    private fun findEditorView(): View? {
        fun find(view: View): View? {
            if (view.onCheckIsTextEditor()) return view
            if (view is ViewGroup) {
                for (index in 0 until view.childCount) find(view.getChildAt(index))?.let { return it }
            }
            return null
        }
        return WindowInspector.getGlobalWindowViews().firstNotNullOfOrNull(::find)
    }

    private fun inputConnection(attributes: EditorInfo = EditorInfo()) = ui.runOnIdle {
        requireNotNull(findEditorView()?.onCreateInputConnection(attributes)) { "No native editor connection" }
    }
}
