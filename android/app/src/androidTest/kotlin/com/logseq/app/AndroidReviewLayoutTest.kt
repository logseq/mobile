package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LocalLuiSemanticColors
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidReviewLayoutTest {
    @get:Rule val ui = createComposeRule()
    private var bridge: LogseqNativeBridge? = null
    private val events = mutableListOf<LuiEvent>()

    @After fun closeBridge() { bridge?.let { ui.runOnIdle { it.close() } } }

    private fun app(error: String? = null) {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(onEvent = { events.add(it); dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        val filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        val result = JSONObject().put("graphName", "Review graph").put("selectedGraphId", "review-layout")
            .put("isGraphUnlocked", true).put("syncConnected", false).put("outlinerRows", JSONArray())
        if (error != null) result.put("pendingSyncError", error)
        filter.applyJson(native.applySnapshot(JSONObject().put("ok", true).put("result", result).toString()))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(root) }
            }
        }
    }

    private fun settings() {
        app()
        ui.onNodeWithTag("button.sidebar").performClick()
        ui.onNodeWithTag("button.sidebar.settings").performClick()
    }

    private fun graphForm() {
        app()
        ui.onNodeWithTag("button.sidebar").performClick()
        ui.onNodeWithTag("link.sidebar.graphs").performClick()
        ui.onNodeWithTag("button.graph-add").performClick()
    }

    @Test fun graphActionsAreVisibleOnFirstOpen() {
        graphForm()
        ui.onNodeWithTag("button.graph-add.cancel").assertIsDisplayed()
        ui.onNodeWithTag("button.graph-add.confirm").assertIsDisplayed()
        ui.onNodeWithText("Add sync graph").assertIsDisplayed()
    }

    @Test fun graphFormKeepsActionsReachableWithTheKeyboard() {
        graphForm()
        ui.onNodeWithTag("field.graph-name").performClick().performTextInput("Unsent review graph")
        ui.onNodeWithTag("button.graph-add.cancel").assertIsDisplayed().performClick()
        ui.onNodeWithTag("field.graph-name").assertDoesNotExist()
    }

    @Test fun graphInputsHaveConsistentHorizontalInsets() {
        graphForm()
        val field = ui.onNodeWithTag("field.graph-name").getUnclippedBoundsInRoot()
        val sheet = ui.onNodeWithTag("layout.graph-create.sheet").getUnclippedBoundsInRoot()
        assertTrue("The graph name field has an inset", field.left - sheet.left >= 16.dp)
        assertTrue("The graph name field fills its content width", sheet.right - field.right <= 32.dp)
    }

    @Test fun settingsHasATitleAndPersistentActions() {
        settings()
        ui.onNodeWithText("Settings").assertIsDisplayed()
        ui.onNodeWithTag("button.connection.cancel").assertIsDisplayed()
        ui.onNodeWithTag("button.connection.apply").assertIsDisplayed()
        val sheet = ui.onNodeWithTag("layout.settings.sheet").getUnclippedBoundsInRoot()
        val apply = ui.onNodeWithTag("button.connection.apply").getUnclippedBoundsInRoot()
        assertTrue("Settings actions align to the trailing inset", sheet.right - apply.right <= 32.dp)
    }

    @Test fun settingsMenuSelectionSurvivesItsOwnDismissal() {
        settings()
        ui.onNodeWithTag("picker.settings.appearance").performClick()
        ui.onNodeWithText("Dark").performClick()
        ui.onNodeWithTag("picker.settings.appearance.option.dark").assertDoesNotExist()
        ui.onNodeWithText("Dark").assertIsDisplayed()
    }

    @Test fun syncLabelsAndValuesHaveNativeRowSpacing() {
        app("Server unavailable")
        ui.onNodeWithTag("sync.failed").performClick()
        val label = ui.onNodeWithText("Status", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val value = ui.onNodeWithText("Sync failed", useUnmergedTree = true).getUnclippedBoundsInRoot()
        assertTrue("Sync values must be separated: label=$label value=$value", value.left - label.right >= 16.dp)
    }

    @Test fun settingsSwitchRowsFillTheAvailableWidthAndToggleOnce() {
        settings()
        val spelling = ui.onNodeWithTag("switch.settings.spell-check")
        spelling.performScrollTo().assertWidthIsAtLeast(280.dp).assertIsOn()
        ui.onNodeWithText("Spell check").performClick()
        spelling.assertIsOff()
        val correction = ui.onNodeWithTag("switch.settings.auto-correction")
        correction.performScrollTo().assertWidthIsAtLeast(280.dp).assertIsOn()
        ui.onNodeWithText("Auto-correction").performClick()
        correction.assertIsOff()
    }

    @Test fun longSyncErrorsScrollWithoutHidingActions() {
        app((1..24).joinToString("\n") { "Network error line $it: server is unavailable" })
        ui.onNodeWithTag("sync.failed").performClick()
        ui.onNodeWithText("Sync status").assertIsDisplayed()
        ui.onNodeWithTag("button.sync-now").assertIsDisplayed()
        ui.onNodeWithTag("button.sync.done").assertIsDisplayed()
        val sheet = ui.onNodeWithTag("form.sync-status").getUnclippedBoundsInRoot()
        val sync = ui.onNodeWithTag("button.sync-now").getUnclippedBoundsInRoot()
        assertTrue("Sync actions align to the trailing inset", sheet.right - sync.right <= 32.dp)
        ui.onNodeWithTag("sync.error").performScrollTo()
        ui.onNodeWithTag("button.sync.done").assertIsDisplayed().performClick()
        ui.onNodeWithTag("sync.error").assertDoesNotExist()
    }

    private fun button(variant: String, dark: Boolean = false, scopedLink: Color? = null, grow: Boolean = false) {
        val backend = LuiBackend(onEvent = { events.add(it) })
        val ops = JSONArray()
        fun node(id: Int, kind: String, parent: Int?, props: Map<String, Any> = emptyMap()) {
            ops.put(JSONObject().put("op", "create-node").put("id", id).put("kind", kind))
            props.forEach { (key, value) -> ops.put(JSONObject().put("op", "set-prop").put("id", id)
                .put("property", key).put("value", value)) }
            if (parent != null) ops.put(JSONObject().put("op", "insert-child").put("parent", parent)
                .put("child", id).put("index", 0))
        }
        node(1, "root", null)
        node(2, "row", 1, mapOf("width" to 300))
        node(3, "button", 2, mapOf("text" to "Themed action", "variant" to variant, "grow" to if (grow) 1 else 0))
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = if (dark) LogseqTheme.darkScheme else LogseqTheme.lightScheme) {
                CompositionLocalProvider(LocalLuiSemanticColors provides
                    (scopedLink?.let { mapOf("link" to it) } ?: emptyMap())) {
                    Box(Modifier.fillMaxSize()) { backend.Content(1) }
                }
            }
        }
    }

    private fun actionColor(): Color {
        val layouts = mutableListOf<TextLayoutResult>()
        ui.onNodeWithText("Themed action").performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        return layouts.single().layoutInput.style.color
    }

    @Test fun lightActionButtonsUseTheLogseqAccent() {
        button("ghost")
        assertEquals(Color(0xFF1B6898), actionColor())
    }

    @Test fun darkActionButtonsUseTheLogseqAccent() {
        button("ghost", dark = true)
        assertEquals(Color(0xFF9BD3D4), actionColor())
    }

    @Test fun linkButtonsUseTheScopedThemeToken() {
        button("ghost", scopedLink = Color(0xFF235B49))
        assertEquals(Color(0xFF235B49), actionColor())
    }

    @Test fun primaryButtonsFillTheirAllocatedRowSpace() {
        button("primary", grow = true)
        ui.onNodeWithText("Themed action").assertWidthIsAtLeast(290.dp)
    }

    @Test fun tonalButtonsFillTheirAllocatedRowSpace() {
        button("secondary", grow = true)
        ui.onNodeWithText("Themed action").assertWidthIsAtLeast(290.dp)
    }

    @Test fun outlineButtonsFillTheirAllocatedRowSpace() {
        button("outline", grow = true)
        ui.onNodeWithText("Themed action").assertWidthIsAtLeast(290.dp)
    }
}
