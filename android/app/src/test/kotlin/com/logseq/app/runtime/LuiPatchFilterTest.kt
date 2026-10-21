package com.logseq.app.runtime

import dev.lui.LuiBackend
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import dev.lui.LuiWireValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LuiPatchFilterTest {
    private class Harness(kind: String = "text") {
        val backend = LuiBackend()
        val filter = LuiPatchFilter(backend)
        var generation = 0

        init {
            send("""{"op":"create-node","id":1,"kind":"root"},
                {"op":"create-node","id":2,"kind":"column"},
                {"op":"create-node","id":3,"kind":"$kind"},
                {"op":"insert-child","parent":1,"child":2,"index":0},
                {"op":"insert-child","parent":2,"child":3,"index":0}""")
        }

        fun send(operations: String) {
            filter.applyJson("""{"generation":${generation + 1},"ops":[$operations]}""")
            generation++
        }

        fun property(name: String) = backend.node(3)!!.properties[name]?.scalarValue
    }

    @Test fun unsupportedHintsDoNotHideAllowedTextOrUnicode() {
        val h = Harness()
        h.send("""{"op":"set-prop","id":3,"property":"container-relative-frame","value":"horizontal"},
            {"op":"set-prop","id":3,"property":"container-relative-frame-inset","value":8},
            {"op":"set-prop","id":3,"property":"text","value":"中文 😀 \"quoted\"\nnext"}""")
        assertEquals("中文 😀 \"quoted\"\nnext", h.property("text"))
        assertNull(h.property("container-relative-frame"))
        assertNull(h.property("container-relative-frame-inset"))
    }

    @Test fun iconButtonsKeepTheExistingCenteredGlyphBehavior() {
        for (kind in listOf("button", "toggle-button")) {
            val h = Harness(kind)
            h.send("""{"op":"set-prop","id":3,"property":"size","value":"icon"}""")
            assertEquals("icon", h.property("size"))
            assertEquals("center", h.property("text-alignment"))
        }
    }

    @Test fun presentationRulesRemainSpecificToNodeKindAndValue() {
        val button = Harness("button")
        button.send("""{"op":"set-prop","id":3,"property":"icon-placement","value":"leading"}""")
        assertEquals("leading", button.property("icon-placement"))
        val text = Harness()
        text.send("""{"op":"set-prop","id":3,"property":"icon-placement","value":"leading"}""")
        assertNull(text.property("icon-placement"))
        val row = Harness("row")
        row.send("""{"op":"set-prop","id":3,"property":"role","value":"treeitem"}""")
        assertEquals("treeitem", row.property("role"))
        assertTrue(LuiPatchFilter.isUnsupportedPresentationHint("avatar", "padding-horizontal", 4))
        assertFalse(LuiPatchFilter.isUnsupportedPresentationHint("row", "padding-horizontal", 4))
        assertTrue(LuiPatchFilter.isUnsupportedPresentationHint("dialog", "style-class", "modal"))
    }

    @Test fun ignoredRemovalThenAllowedReplacementAndRemovalStayInOrder() {
        val h = Harness("button")
        h.send("""{"op":"set-prop","id":3,"property":"icon-placement","value":"center"}""")
        h.send("""{"op":"remove-prop","id":3,"property":"icon-placement"}""")
        h.send("""{"op":"set-prop","id":3,"property":"icon-placement","value":"trailing"}""")
        assertEquals("trailing", h.property("icon-placement"))
        h.send("""{"op":"remove-prop","id":3,"property":"icon-placement"}""")
        assertNull(h.property("icon-placement"))
    }

    @Test fun rejectedBatchDoesNotCommitFilterBookkeeping() {
        val h = Harness("button")
        h.send("""{"op":"set-prop","id":3,"property":"icon-placement","value":"leading"}""")
        assertThrows(IllegalStateException::class.java) {
            h.send("""{"op":"set-prop","id":3,"property":"icon-placement","value":"center"},
                {"op":"insert-child","parent":999,"child":3,"index":0}""")
        }
        assertEquals("leading", h.property("icon-placement"))
        h.send("""{"op":"remove-prop","id":3,"property":"icon-placement"}""")
        assertNull(h.property("icon-placement"))
    }

    @Test fun droppedNodeIdsCanBeReusedWithDifferentPresentationRules() {
        val h = Harness("button")
        h.send("""{"op":"remove-child","parent":2,"child":3},
            {"op":"drop-node","id":3},
            {"op":"create-node","id":3,"kind":"text"},
            {"op":"insert-child","parent":2,"child":3,"index":0},
            {"op":"set-prop","id":3,"property":"icon-placement","value":"leading"},
            {"op":"set-prop","id":3,"property":"text","value":"Replacement"}""")
        assertEquals("Replacement", h.property("text"))
        assertNull(h.property("icon-placement"))
    }

    @Test fun malformedInputLeavesTheNextValidGenerationUsable() {
        val h = Harness()
        assertThrows(Exception::class.java) { h.filter.applyJson("{broken") }
        h.send("""{"op":"set-prop","id":3,"property":"text","value":"Recovered"}""")
        assertEquals("Recovered", h.property("text"))
    }

    @Test fun emptyBatchStillAdvancesTheBackendGeneration() {
        val h = Harness()
        h.send("")
        h.send("""{"op":"set-prop","id":3,"property":"text","value":"After empty"}""")
        assertEquals("After empty", h.property("text"))
    }

    @Test fun extensionRegistrationTextAndDefaultRestorationPassThrough() {
        val registry = LuiExtensionRegistry()
        registry.register("filter-test", "fp", properties = listOf(
            LuiExtensionProperty("title", LuiExtensionValueKind.STRING, defaultValue = LuiWireValue.Str("Untitled")),
        ), builder = {})
        val backend = LuiBackend(extensions = registry)
        val filter = LuiPatchFilter(backend)
        filter.applyJson("""{"generation":1,"ops":[
            {"op":"create-node","id":1,"kind":"root"},
            {"op":"create-extension","id":3,"identifier":"filter-test","fingerprint":"fp"},
            {"op":"insert-child","parent":1,"child":3,"index":0}]}""")
        filter.applyJson("""{"generation":2,"ops":[
            {"op":"set-extension-prop","id":3,"property":"title","value":"中文 😀 \"quoted\""}]}""")
        assertEquals("中文 😀 \"quoted\"", backend.extensionNode(3)!!.properties["title"]?.scalarValue)
        filter.applyJson("""{"generation":3,"ops":[
            {"op":"remove-extension-prop","id":3,"property":"title"}]}""")
        assertEquals("Untitled", backend.extensionNode(3)!!.properties["title"]?.scalarValue)
    }
}
