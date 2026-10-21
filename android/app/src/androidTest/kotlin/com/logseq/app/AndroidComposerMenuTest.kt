package com.logseq.app

import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inspector.WindowInspector
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidComposerMenuTest {
    @get:Rule val ui = createComposeRule()
    private var bridge: LogseqNativeBridge? = null
    private val events = mutableListOf<LuiEvent>()

    @After fun closeBridge() { bridge?.let { ui.runOnIdle { it.close() } } }

    private fun composer() {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(
            onEvent = { dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it },
            icons = logseqIconResolver,
        )
        val filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        filter.applyJson(native.applySnapshot("""{"ok":true,"result":{
            "graphName":"Composer test","selectedGraphId":"composer-test",
            "isGraphUnlocked":true,"outlinerRows":[]}}"""))
        content(backend, root)
        ui.onNodeWithTag("button.composer.expand").performClick()
        ui.onNodeWithTag("field.composer").performTextInput("Unsent draft 中文")
    }

    private fun content(backend: LuiBackend, root: Long) {
        ui.setContent {
            MaterialTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(root) }
            }
        }
    }

    private fun popupKeyBack() = ui.runOnIdle {
        val popup = WindowInspector.getGlobalWindowViews().last()
        popup.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK))
        popup.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK))
    }

    @Test fun attachmentDismissalRetainsTheNativeExitTransition() {
        composer()
        ui.onNodeWithTag("button.attachment").performClick()
        ui.onNodeWithText("File").assertIsDisplayed()
        ui.mainClock.autoAdvance = false
        popupKeyBack()
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithText("File").assertExists()
        ui.mainClock.advanceTimeBy(500)
        ui.onNodeWithText("File").assertDoesNotExist()
        ui.mainClock.autoAdvance = true
        ui.onNodeWithTag("field.composer").assertTextEquals("Unsent draft 中文")
        ui.onNodeWithTag("button.attachment").performClick()
        ui.onNodeWithText("Photo").assertIsDisplayed()
    }

    @Test fun selectingStatusRetainsTheExitTransitionAndMarksTheReopenedChoice() {
        composer()
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Todo").assertIsDisplayed()
        ui.mainClock.autoAdvance = false
        ui.onNodeWithText("Todo").performClick()
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithText("Todo").assertExists()
        ui.mainClock.advanceTimeBy(500)
        ui.onNodeWithText("Todo").assertDoesNotExist()
        ui.mainClock.autoAdvance = true
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Todo").assertIsSelected()
        ui.onNodeWithText("Clear task status").performClick()
        ui.onNodeWithTag("field.composer").assertTextEquals("Unsent draft 中文")
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Clear task status").assertDoesNotExist()
    }

    @Test fun outsideDismissalDoesNotChangeTheDraftOrStatus() {
        composer()
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Todo").assertIsDisplayed()
        ui.runOnIdle {
            val now = SystemClock.uptimeMillis()
            val event = MotionEvent.obtain(now, now, MotionEvent.ACTION_OUTSIDE, -1f, -1f, 0)
            try { WindowInspector.getGlobalWindowViews().last().dispatchTouchEvent(event) }
            finally { event.recycle() }
        }
        ui.onNodeWithText("Todo").assertDoesNotExist()
        ui.onNodeWithTag("field.composer").assertTextEquals("Unsent draft 中文")
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Clear task status").assertDoesNotExist()
    }

    @Test fun taskStatusChoicesExposeNativeSingleSelectionSemantics() {
        composer()
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Todo")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.RadioButton))
    }

    @Test fun tappingOutsideTheComposerClosesItAndPreservesTheDraft() {
        composer()
        ui.onNodeWithTag("surface.composer.dismiss").performClick()
        ui.onNodeWithTag("field.composer").assertDoesNotExist()
        ui.onNodeWithTag("button.composer.expand").assertIsDisplayed().performClick()
        ui.onNodeWithTag("field.composer").assertTextEquals("Unsent draft 中文")
    }

    private fun retainedMenu(enabled: Boolean = true) {
        val backend = LuiBackend(onEvent = { events.add(it) }, icons = logseqIconResolver)
        assertTrue(backend.applyJson("""{"generation":1,"ops":[
            {"op":"create-node","id":1,"kind":"root"},
            {"op":"create-node","id":2,"kind":"menu-trigger"},
            {"op":"set-prop","id":2,"property":"text","value":"Actions"},
            {"op":"create-node","id":3,"kind":"dropdown-menu"},
            {"op":"create-node","id":4,"kind":"menu-item"},
            {"op":"set-prop","id":4,"property":"text","value":"Choose"},
            {"op":"set-prop","id":4,"property":"enabled","value":$enabled},
            {"op":"set-prop","id":4,"property":"press-enabled","value":true},
            {"op":"insert-child","parent":3,"child":4,"index":0},
            {"op":"insert-child","parent":2,"child":3,"index":0},
            {"op":"insert-child","parent":1,"child":2,"index":0}]}"""))
        content(backend, 1)
        ui.onNodeWithText("Actions").performClick()
    }

    @Test fun choosingARetainedActionClosesTheMenuAndEmitsExactlyOnce() {
        retainedMenu()
        ui.onNodeWithText("Choose").performClick()
        ui.onNodeWithText("Choose").assertDoesNotExist()
        ui.runOnIdle { assertEquals(1, events.filterIsInstance<LuiEvent.Press>().size) }
        ui.onNodeWithText("Actions").performClick()
        ui.onNodeWithText("Choose").assertIsDisplayed()
    }

    @Test fun disabledActionsCannotBeActivatedAndBackStillDismisses() {
        retainedMenu(enabled = false)
        ui.onNodeWithText("Choose").assertIsNotEnabled()
        ui.runOnIdle { assertTrue(events.filterIsInstance<LuiEvent.Press>().isEmpty()) }
        popupKeyBack()
        ui.onNodeWithText("Choose").assertDoesNotExist()
    }
}
