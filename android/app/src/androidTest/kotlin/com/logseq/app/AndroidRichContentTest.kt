package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.click
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import dev.lui.LocalLuiSemanticColors
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

@RunWith(AndroidJUnit4::class)
class AndroidRichContentTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()

    private fun render(markup: String, completed: Boolean = false, secondMarkup: String? = null,
        linkColor: Color? = null, dark: Boolean = false): LuiBackend {
        val registry = logseqExtensionRegistry { it }
        val backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val ops = JSONArray()
            .put(JSONObject().put("op", "create-node").put("id", 1).put("kind", if (secondMarkup == null) "root" else "column"))
            .put(JSONObject().put("op", "create-extension").put("id", 2)
                .put("identifier", "outliner-block-content")
                .put("fingerprint", registry.registration("outliner-block-content")!!.fingerprint))
            .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 2).put("index", 0))
        mapOf(
            "block-id" to "rich-block", "title" to "Readable fallback", "markup-json" to markup,
            "is-completed" to completed, "is-asset" to false, "asset-type" to "",
            "local-path" to "", "youtube-target-url" to "",
        ).forEach { (key, value) -> ops.put(property(key, value)) }
        if (secondMarkup != null) {
            ops.put(JSONObject().put("op", "create-extension").put("id", 3)
                .put("identifier", "outliner-block-content")
                .put("fingerprint", registry.registration("outliner-block-content")!!.fingerprint))
                .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 3).put("index", 1))
            mapOf("block-id" to "timestamp-block", "title" to "Timestamp", "markup-json" to secondMarkup,
                "is-completed" to false, "is-asset" to false, "asset-type" to "", "local-path" to "", "youtube-target-url" to "")
                .forEach { (key, value) -> ops.put(property(key, value).put("id", 3)) }
        }
        val applied = backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString())
        assertTrue(backend.lastError, applied)
        ui.setContent {
            MaterialTheme(colorScheme = if (dark) LogseqTheme.darkScheme else LogseqTheme.lightScheme,
                typography = LogseqTheme.typography) {
                CompositionLocalProvider(LocalLuiSemanticColors provides
                    (linkColor?.let { mapOf("link" to it) } ?: emptyMap())) {
                    Box(Modifier.fillMaxSize()) { backend.Content(1) }
                }
            }
        }
        return backend
    }

    private fun property(name: String, value: Any) = JSONObject()
        .put("op", "set-extension-prop").put("id", 2).put("property", name).put("value", value)

    private fun layout(text: String): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        ui.onNodeWithText(text).assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        return results.single()
    }

    private fun assertLongPressSelects(markup: String, visible: String) {
        render(markup)
        ui.onNodeWithText(visible).performTouchInput { longClick() }
        ui.runOnIdle {
            assertEquals("A long press selects the block exactly once without editing", listOf("drag-start"),
                events.filterIsInstance<LuiEvent.Extension>().map { it.name })
        }
    }

    @Test fun plainBodyLongPressSelectsInsteadOfEditing() =
        assertLongPressSelects("""[{"type":"text","text":"Plain block"}]""", "Plain block")

    @Test fun richBodyLongPressSelectsInsteadOfEditing() =
        assertLongPressSelects("""[{"type":"emphasis","style":"bold","children":[{"type":"text","text":"Bold block"}]}]""", "Bold block")

    @Test fun quoteLongPressSelectsInsteadOfEditing() =
        assertLongPressSelects("""[{"type":"quote","children":[{"type":"text","text":"Quote block"}]}]""", "Quote block")

    @Test fun codeLongPressSelectsInsteadOfEditing() =
        assertLongPressSelects("""[{"type":"codeBlock","style":"python","text":"print(42)"}]""", "print(42)")

    @Test fun mathLongPressSelectsInsteadOfEditing() {
        render("""[{"type":"math","style":"display","text":"x^2"}]""")
        ui.waitUntil(10_000) {
            ui.onAllNodesWithContentDescription("x^2").fetchSemanticsNodes().isNotEmpty()
        }
        ui.onNodeWithContentDescription("x^2").performTouchInput { longClick() }
        ui.runOnIdle {
            assertEquals("A formula long press selects the block exactly once", listOf("drag-start"),
                events.filterIsInstance<LuiEvent.Extension>().map { it.name })
        }
    }

    @Test fun malformedBodyLongPressStillSelects() = assertLongPressSelects("not-json", "Readable fallback")

    @Test fun shortBodyTapStillEditsExactlyOnce() {
        render("""[{"type":"text","text":"Tap to edit"}]""")
        ui.onNodeWithText("Tap to edit").performTouchInput { click() }
        ui.runOnIdle { assertEquals(listOf("edit"), events.filterIsInstance<LuiEvent.Extension>().map { it.name }) }
    }

    private fun assertLinkTheme(dark: Boolean, color: Color) {
        render("""[{"type":"nodeReference","uuid":"page-target","title":"Destination"},
            {"type":"text","text":" "},{"type":"link","url":"https://logseq.com","children":[{"type":"text","text":"Website"}]}]""",
            linkColor = color, dark = dark)
        val text = layout("[[Destination]] Website").layoutInput.text
        for (label in listOf("Destination", "Website")) {
            val offset = text.text.indexOf(label)
            assertTrue("$label follows the scoped Logseq link token", text.spanStyles.any {
                it.start <= offset && it.end > offset && it.item.color == color
            })
        }
    }

    @Test fun lightLinksUseTheScopedLogseqTheme() = assertLinkTheme(false, Color(0xFF1B6898))
    @Test fun darkLinksUseTheScopedLogseqTheme() = assertLinkTheme(true, Color(0xFF9BD3D4))

    @Test fun timestampsSeekTheExistingMatchingPlayerAcrossBlocks() {
        render("""[{"type":"video","url":"https://youtu.be/abcdefghijk","embedURL":"http://127.0.0.1:18789/embed/abcdefghijk?playsinline=1"},
            {"type":"video","url":"https://youtu.be/lmnopqrstuv","embedURL":"http://127.0.0.1:18789/embed/lmnopqrstuv?playsinline=1"}]""", secondMarkup = """[
            {"type":"youtubeTimestamp","text":"1:23","seconds":83,"url":"https://youtu.be/abcdefghijk","embedURL":"http://127.0.0.1:18789/embed/abcdefghijk?start=83"}]""")
        ui.onNodeWithText("◷ 1:23").assertIsDisplayed()
        val before = nativeWebViews()
        assertEquals("Timestamps must not create another player", 2, before.size)
        ui.onNodeWithText("◷ 1:23").performClick()
        ui.waitUntil(5_000) { nativeWebViews().any { view ->
            var matches = false
            ui.runOnIdle { matches = view.originalUrl?.contains("abcdefghijk?playsinline=1&start=83") == true }
            matches
        } }
        val after = nativeWebViews()
        assertEquals(before.toSet(), after.toSet())
        ui.runOnIdle {
            assertTrue(after.single { it.originalUrl.orEmpty().contains("lmnopqrstuv") }.originalUrl.orEmpty().endsWith("playsinline=1"))
        }
    }

    @Test fun timestampWithoutAValidTargetStaysReadableWithoutAnotherPlayer() {
        render("""[{"type":"youtubeTimestamp","text":"1:23","seconds":-1,"url":""}]""")
        ui.onNodeWithText("◷ 1:23").assertIsDisplayed()
        assertTrue(nativeWebViews().isEmpty())
    }

    private fun nativeWebViews(): List<android.webkit.WebView> {
        val result = mutableListOf<android.webkit.WebView>()
        fun collect(view: android.view.View) {
            if (view is android.webkit.WebView) result.add(view)
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) collect(view.getChildAt(index))
        }
        ui.runOnIdle { android.view.inspector.WindowInspector.getGlobalWindowViews().forEach(::collect) }
        return result
    }

    @Test fun nestedEmphasisPreservesUnicodeTextAndBothStyles() {
        render("""[{"type":"text","text":"Before "},{"type":"emphasis","style":"bold","children":[
            {"type":"text","text":"bold "},{"type":"emphasis","style":"italic","children":[
            {"type":"text","text":"中文 😀"}]}]},{"type":"text","text":" after"}]""")
        val text = layout("Before bold 中文 😀 after").layoutInput.text
        val offset = text.text.indexOf("中文")
        assertTrue("Nested text remains bold", text.spanStyles.any {
            it.start <= offset && it.end > offset && it.item.fontWeight == FontWeight.Bold
        })
        assertTrue("Nested text remains italic", text.spanStyles.any {
            it.start <= offset && it.end > offset && it.item.fontStyle == FontStyle.Italic
        })
    }

    @Test fun quotationKeepsNestedContentAndReferenceNavigation() {
        render("""[{"type":"quote","children":[{"type":"text","text":"Quoted "},
            {"type":"emphasis","style":"bold","children":[{"type":"text","text":"idea "}]},
            {"type":"nodeReference","uuid":"page-target","title":"Destination"}]}]""")
        val text = "Quoted idea [[Destination]]"
        // ClickableText routes from a character location, so tap the reference itself.
        val rendered = layout(text)
        val character = rendered.layoutInput.text.text.indexOf("Destination")
        val bounds = rendered.getBoundingBox(character)
        ui.onNodeWithText(text).performTouchInput { click(bounds.center) }
        ui.runOnIdle {
            assertTrue(events.filterIsInstance<LuiEvent.Extension>().any {
                it.name == "open-node" && it.values["uuid"] == "page-target"
            })
        }
    }

    @Test fun completedContentRetainsUnderlineAndStrikeThrough() {
        render("""[{"type":"emphasis","style":"underline","children":[
            {"type":"text","text":"Completed and underlined"}]}]""", completed = true)
        val text = layout("Completed and underlined").layoutInput.text
        assertTrue("Underline and completion are both visible", text.spanStyles.any {
            it.item.textDecoration?.contains(TextDecoration.Underline) == true &&
                it.item.textDecoration?.contains(TextDecoration.LineThrough) == true
        })
    }

    @Test fun quotationWithEmptyChildrenRemainsEmptyAndDoesNotInventText() {
        render("""[{"type":"quote","children":[]},{"type":"text","text":"After empty quote"}]""")
        ui.onNodeWithText("After empty quote").assertIsDisplayed()
        ui.onNodeWithText("Readable fallback").assertDoesNotExist()
    }

    @Test fun malformedMarkupHasReadableEditableFallback() {
        render("not-json")
        ui.onNodeWithText("Readable fallback").assertIsDisplayed().performClick()
        ui.runOnIdle {
            assertTrue(events.filterIsInstance<LuiEvent.Extension>().any {
                it.name == "edit" && it.values["uuid"] == "rich-block"
            })
        }
    }

    @Test fun replacingMarkupUpdatesTheVisibleContent() {
        val backend = render("""[{"type":"text","text":"Original"}]""")
        ui.onNodeWithText("Original").assertIsDisplayed()
        ui.runOnIdle {
            val updated = """[{"type":"emphasis","style":"italic","children":[{"type":"text","text":"Updated"}]}]"""
            assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 2)
                .put("ops", JSONArray().put(property("markup-json", updated))).toString()))
        }
        ui.onNodeWithText("Updated").assertTextEquals("Updated")
        ui.onNodeWithText("Original").assertDoesNotExist()
    }

    @Test fun plainTextExposesEditingToAccessibility() {
        render("""[{"type":"text","text":"Accessible block"}]""")
        ui.onNodeWithText("Accessible block").assertHasClickAction().performClick()
        ui.runOnIdle {
            assertTrue(events.filterIsInstance<LuiEvent.Extension>().any {
                it.name == "edit" && it.values["uuid"] == "rich-block"
            })
        }
    }

    @Test fun quotationExposesEditingToAccessibility() {
        render("""[{"type":"quote","children":[{"type":"text","text":"Accessible quote"}]}]""")
        ui.onNodeWithText("Accessible quote").assertHasClickAction().performClick()
        ui.runOnIdle {
            assertTrue(events.filterIsInstance<LuiEvent.Extension>().any {
                it.name == "edit" && it.values["uuid"] == "rich-block"
            })
        }
    }
}
