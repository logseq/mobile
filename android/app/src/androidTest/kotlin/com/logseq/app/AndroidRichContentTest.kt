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
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
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

@RunWith(AndroidJUnit4::class)
class AndroidRichContentTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()

    private fun render(markup: String, completed: Boolean = false): LuiBackend {
        val registry = logseqExtensionRegistry { it }
        val backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val ops = JSONArray()
            .put(JSONObject().put("op", "create-node").put("id", 1).put("kind", "root"))
            .put(JSONObject().put("op", "create-extension").put("id", 2)
                .put("identifier", "outliner-block-content")
                .put("fingerprint", registry.registration("outliner-block-content")!!.fingerprint))
            .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 2).put("index", 0))
        mapOf(
            "block-id" to "rich-block", "title" to "Readable fallback", "markup-json" to markup,
            "is-completed" to completed, "is-asset" to false, "asset-type" to "",
            "local-path" to "", "youtube-target-url" to "",
        ).forEach { (key, value) -> ops.put(property(key, value)) }
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))
        ui.setContent {
            MaterialTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(1) }
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
