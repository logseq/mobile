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
import org.json.JSONObject
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
    private var patchFilter: LuiPatchFilter? = null
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
        patchFilter = filter
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

    private fun effect(kind: String): JSONObject {
        var found: JSONObject? = null
        ui.waitUntil(timeoutMillis = 5000) {
            ui.runOnIdle {
                repeat(24) {
                    val raw = bridge!!.takeEffect()
                    if (raw.isNotEmpty()) {
                        val result = JSONObject(raw)
                        result.optString("patch").takeIf { it.isNotEmpty() }?.let { patchFilter!!.applyJson(it) }
                        result.optJSONObject("effect")?.let { if (it.optString("kind") == kind) found = it }
                    }
                }
            }
            found != null
        }
        return found!!
    }

    private fun resolve(effect: JSONObject, succeeded: Boolean = true) = ui.runOnIdle {
        bridge!!.resolveEffect(effect.getLong("id"), succeeded, if (succeeded) "" else "Storage failed")
            .takeIf { it.isNotEmpty() }?.let { patchFilter!!.applyJson(it) }
    }

    private fun tagCatalog(load: JSONObject, graph: String = "composer-test", tag: String = "project", title: String = "Project") {
        ui.runOnIdle {
            bridge!!.applySnapshot(JSONObject().put("ok", true).put("result", JSONObject()
                .put("selectedGraphId", graph).put("composerTagChoices", org.json.JSONArray()
                    .put(JSONObject().put("uuid", tag).put("title", title)))).toString())
                .takeIf { it.isNotEmpty() }?.let { patchFilter!!.applyJson(it) }
        }
        resolve(load)
    }

    @Test fun tagsUseTheSharedNativePickerAndRecoverFailedCaptures() {
        composer()
        val attachment = ui.onNodeWithTag("button.attachment").fetchSemanticsNode().boundsInRoot
        val status = ui.onNodeWithTag("button.task-status").fetchSemanticsNode().boundsInRoot
        val tags = ui.onNodeWithTag("button.composer.tags").fetchSemanticsNode().boundsInRoot
        assertTrue("Hashtag follows attachment and task status", attachment.left < status.left && status.left < tags.left)
        fun openTags() {
            ui.onNodeWithTag("button.composer.tags").performClick()
            tagCatalog(effect("load-composer-tags"))
            ui.onNodeWithTag("view.edit.value.composer.tags").assertIsDisplayed()
        }
        openTags()
        ui.onNodeWithTag("view.edit.option.composer.tags.project").performClick()
        ui.onNodeWithTag("view.edit.save.composer.tags").performClick()
        ui.onNodeWithTag("button.composer.tag.remove.project").assertIsDisplayed()
        openTags()
        ui.onNodeWithTag("view.edit.value.composer.tags").performTextInput("Mobile")
        ui.onNodeWithTag("view.edit.create.composer.tags").performClick()
        ui.onNodeWithTag("view.edit.save.composer.tags").performClick()
        ui.onNodeWithTag("button.composer.tag.remove.new:mobile").assertIsDisplayed()
        ui.onNodeWithTag("button.composer.tag.remove.project").performClick()
        openTags()
        ui.onNodeWithTag("view.edit.value.composer.tags").performTextInput("Discard")
        ui.onNodeWithTag("view.edit.create.composer.tags").performClick()
        ui.onNodeWithTag("view.edit.cancel.composer.tags").performClick()
        ui.onNodeWithTag("button.composer.tag.remove.new:discard").assertDoesNotExist()
        ui.onNodeWithTag("field.composer").assertTextEquals("Unsent draft 中文")
        ui.onNodeWithTag("button.send").performClick()
        val send = effect("send-tagged")
        val payload = JSONObject(send.getString("text"))
        assertEquals("Unsent draft 中文", payload.getString("text"))
        assertEquals("Mobile", payload.getJSONObject("tags").getJSONArray("newValues").getString(0))
        assertEquals(0, payload.getJSONObject("tags").getJSONArray("selectedValues").length())
        resolve(send, succeeded = false)
        ui.onNodeWithTag("field.composer").assertTextEquals("Unsent draft 中文")
        ui.onNodeWithTag("button.composer.tag.remove.new:mobile").assertIsDisplayed().performClick()
        ui.onNodeWithTag("button.send").performClick()
        val retry = effect("send-capture")
        assertEquals("Unsent draft 中文", retry.getString("text"))
        resolve(retry)
        ui.onNodeWithTag("field.composer").assert(SemanticsMatcher.expectValue(
            SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
        ui.onNodeWithTag("button.composer.tag.remove.new:mobile").assertDoesNotExist()
    }

    @Test fun changingGraphsDismissesOldTagsAndIgnoresAnOldCatalogFailure() {
        composer()
        ui.onNodeWithTag("button.composer.tags").performClick()
        tagCatalog(effect("load-composer-tags"))
        ui.onNodeWithTag("view.edit.option.composer.tags.project").performClick()
        ui.onNodeWithTag("view.edit.save.composer.tags").performClick()
        ui.onNodeWithTag("button.composer.tags").performClick()
        val old = effect("load-composer-tags")
        ui.runOnIdle {
            bridge!!.applySnapshot("""{"ok":true,"result":{"selectedGraphId":"other","graphName":"Other","isGraphUnlocked":true}}""")
                .takeIf { it.isNotEmpty() }?.let { patchFilter!!.applyJson(it) }
        }
        ui.onNodeWithTag("button.composer.tag.remove.project").assertDoesNotExist()
        ui.onNodeWithTag("view.edit.value.composer.tags").assertDoesNotExist()
        ui.onNodeWithTag("button.composer.tags").performClick()
        val current = effect("load-composer-tags")
        resolve(old, succeeded = false)
        tagCatalog(current, graph = "other", tag = "book", title = "Book")
        ui.onNodeWithTag("view.edit.option.composer.tags.project").assertDoesNotExist()
        ui.onNodeWithTag("view.edit.option.composer.tags.book").assertIsDisplayed().performClick()
        ui.onNodeWithTag("view.edit.save.composer.tags").performClick()
        ui.onNodeWithTag("button.composer.tag.remove.book").assertIsDisplayed()
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
