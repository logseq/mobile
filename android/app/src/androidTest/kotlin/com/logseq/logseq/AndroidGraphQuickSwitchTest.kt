package com.logseq.logseq

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidGraphQuickSwitchTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()

    private fun renderJournals() {
        val registry = logseqExtensionRegistry()
        val fingerprint = registry.registration("graph-quick-switch")!!.fingerprint
        val backend = LuiBackend(extensions = registry, onEvent = { events.add(it) })
        val applied = backend.applyJson("""
            {"generation":1,"ops":[
                {"op":"create-node","id":1,"kind":"root"},
                {"op":"create-extension","id":2,"identifier":"graph-quick-switch","fingerprint":"$fingerprint"},
                {"op":"set-extension-prop","id":2,"property":"target-id","value":"notes"},
                {"op":"set-extension-prop","id":2,"property":"target-name","value":"Notes"},
                {"op":"set-extension-prop","id":2,"property":"action-label","value":"Switch to Notes"},
                {"op":"create-node","id":3,"kind":"scroll"},
                {"op":"set-prop","id":3,"property":"accessibility-identifier","value":"journal-scroll"},
                {"op":"create-node","id":4,"kind":"spacer"},
                {"op":"set-prop","id":4,"property":"width","value":600},
                {"op":"set-prop","id":4,"property":"height","value":1400},
                {"op":"insert-child","parent":1,"child":2,"index":0},
                {"op":"insert-child","parent":2,"child":3,"index":0},
                {"op":"insert-child","parent":3,"child":4,"index":0}
            ]}
        """.trimIndent())
        assertTrue(backend.lastError, applied)
        ui.setContent { MaterialTheme { backend.Content(1) } }
    }

    @Test fun idlePreviewLetsJournalsScrollFromItsBounds() {
        renderJournals()
        val scroll = ui.onNodeWithTag("journal-scroll")
        val startY = with(ui.density) { 92.dp.toPx() }
        val endY = with(ui.density) { 12.dp.toPx() }
        val idleOffsetX = with(ui.density) { 48.dp.toPx() }
        scroll.performTouchInput {
            val x = center.x + idleOffsetX
            swipe(Offset(x, startY), Offset(x, endY))
        }
        val position = scroll.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange]
        ui.runOnIdle {
            assertTrue("Journals should scroll underneath the idle preview", position.value() > 0f)
            assertTrue("Vertical scrolling should not switch graphs", events.isEmpty())
        }
    }

    @Test fun accessibilityActionSwitchesToTheSameTargetAsTheSwipe() {
        renderJournals()
        val action = ui.onNode(SemanticsMatcher.keyIsDefined(SemanticsActions.CustomActions))
            .fetchSemanticsNode().config[SemanticsActions.CustomActions].single()
        ui.runOnIdle {
            assertEquals("Switch to Notes", action.label)
            assertTrue(action.action())
            assertEquals(listOf(LuiEvent.Extension(2, "graph-quick-switch", "switch", mapOf("value" to "notes"))), events)
        }
    }
}
