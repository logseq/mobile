package com.logseq.logseq

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.espresso.Espresso.pressBack
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.logseq.runtime.EffectDispatch
import com.logseq.logseq.runtime.LogseqNativeBridge
import com.logseq.logseq.runtime.LuiPatchFilter
import com.logseq.logseq.runtime.dispatchLuiEvent
import com.logseq.logseq.runtime.logseqIconResolver
import com.logseq.logseq.ui.LogseqTheme
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
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

    private fun app(
        error: String? = null,
        projection: JSONObject? = null,
        hapticFeedback: HapticFeedback? = null,
    ): (JSONObject) -> Unit {
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
        fun applyProjection(update: JSONObject) {
            update.keys().forEach { result.put(it, update.get(it)) }
            filter.applyJson(native.applySnapshot(JSONObject().put("ok", true).put("result", result).toString()))
        }
        applyProjection(projection ?: JSONObject())
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                CompositionLocalProvider(LocalHapticFeedback provides (hapticFeedback ?: LocalHapticFeedback.current)) {
                    Box(Modifier.fillMaxSize()) { backend.Content(root) }
                }
            }
        }
        return ::applyProjection
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

    @Test fun completedFlashcardReviewIsCenteredAcrossTheScreen() {
        app(projection = JSONObject().put("flashcardDecks",
            JSONObject().put("completed", true).put("totalCards", 1)))
        ui.onNodeWithTag("button.sidebar").performClick()
        ui.onNodeWithTag("link.sidebar.flashcards").performClick()
        val screen = ui.onNodeWithTag("screen.flashcards").fetchSemanticsNode().boundsInRoot
        val complete = ui.onNodeWithTag("flashcards.complete").fetchSemanticsNode().boundsInRoot
        assertEquals("The completion state is centered on the screen", screen.center.x, complete.center.x, 1f)
    }

    @Test fun flashcardGroupControlsUseTheMainHeader() {
        val groups = JSONArray().put(JSONObject().put("uuid", "project").put("title", "Project cards"))
        fun projection(selected: Any) = JSONObject().put("flashcardDecks",
            JSONObject().put("items", groups).put("selectedUuid", selected))
        val applyProjection = app(projection = projection(JSONObject.NULL))
        ui.onNodeWithTag("button.sidebar").performClick()
        ui.onNodeWithTag("link.sidebar.flashcards").performClick()

        val header = ui.onNodeWithTag("header.main").fetchSemanticsNode().boundsInRoot
        val menu = ui.onNodeWithTag("menu.flashcards.deck")
        val add = ui.onNodeWithTag("button.flashcards.deck.add")
        val menuBounds = menu.fetchSemanticsNode().boundsInRoot
        val addBounds = add.fetchSemanticsNode().boundsInRoot
        assertEquals(header.center.x, menuBounds.center.x, 1f)
        assertTrue(addBounds.left > menuBounds.right && addBounds.bottom <= header.bottom)
        ui.onNodeWithTag("sync.disconnected").assertDoesNotExist()
        ui.onNodeWithTag("button.journal-calendar").assertDoesNotExist()

        fun assertSelection(selected: Any) = ui.runOnIdle {
            val native = checkNotNull(bridge)
            val effect = generateSequence { native.takeEffect().takeIf(String::isNotEmpty) }
                .map { EffectDispatch.decode(it).effect }
                .first { it.kind == "flashcard-deck" }
            val request = JSONObject(effect.text)
            assertEquals("select", request.getString("action"))
            assertEquals(selected, request.get("uuid"))
            applyProjection(projection(selected))
        }

        menu.performClick()
        ui.onNodeWithTag("flashcards.deck.select.project").assertIsDisplayed().performClick()
        assertSelection("project")
        menu.assertTextEquals("Project cards")
        menu.performClick()
        ui.onNodeWithTag("flashcards.deck.select.all").performClick()
        assertSelection(JSONObject.NULL)
        menu.assertTextEquals("All cards")
        add.performClick()
        ui.onNodeWithTag("field.flashcards.deck.name").assertIsDisplayed()
        ui.onNodeWithTag("button.flashcards.deck.cancel").performClick()
        ui.onNodeWithTag("field.flashcards.deck.name").assertDoesNotExist()
    }

    @Test fun graphUnlockFormFillsTheSheetWithEvenInsets() {
        app(projection = JSONObject().put("isGraphEncrypted", true).put("isGraphUnlocked", false))
        val sheet = ui.onNodeWithTag("sheet.graph-unlock").getUnclippedBoundsInRoot()
        val field = ui.onNodeWithTag("field.graph-password").getUnclippedBoundsInRoot()
        assertTrue("The password field has a leading inset", field.left - sheet.left >= 20.dp)
        assertTrue("The password field fills the sheet", sheet.right - field.right <= 32.dp)
        ui.onNodeWithTag("field.graph-password").performClick().performTextInput("local-layout-check")
        ui.onNodeWithTag("button.graph-unlock.cancel").assertIsDisplayed()
        ui.onNodeWithTag("button.graph-unlock").assertIsDisplayed()
    }

    @Test fun sidebarFavoritesAndRecentPagesUseCompactRows() {
        fun pages(prefix: String) = JSONArray().apply {
            repeat(3) { put(JSONObject().put("uuid", "$prefix-$it").put("title", "$prefix $it")) }
        }
        app(projection = JSONObject().put("favorites", pages("favorite")).put("recentPages", pages("recent")))
        ui.onNodeWithTag("button.sidebar").performClick()
        for (prefix in listOf("favorite", "recent")) {
            val first = ui.onNodeWithTag("link.sidebar.page.$prefix-0").getUnclippedBoundsInRoot()
            val second = ui.onNodeWithTag("link.sidebar.page.$prefix-1").getUnclippedBoundsInRoot()
            assertTrue("Adjacent $prefix rows stay compact", second.top - first.top <= 50.dp)
            assertTrue("Page rows retain a 48 dp height", first.bottom - first.top >= 48.dp)
        }
    }

    @Test fun sidebarOverlaysTheStationaryPageAndClosesFromTheBackdrop() {
        val hapticEvents = mutableListOf<HapticFeedbackType>()
        app(hapticFeedback = object : HapticFeedback {
            override fun performHapticFeedback(hapticFeedbackType: HapticFeedbackType) {
                hapticEvents.add(hapticFeedbackType)
            }
        })
        val toolbar = ui.onNodeWithTag("header.main", useUnmergedTree = true)
        val initial = toolbar.getUnclippedBoundsInRoot()
        ui.onRoot().performTouchInput {
            val y = height * 0.55f
            down(Offset(width * 0.08f, y))
            moveTo(Offset(width * 0.36f, y), delayMillis = 450)
        }
        val journalLabel = ui.onNodeWithText("Journals", useUnmergedTree = true).getUnclippedBoundsInRoot()
        assertTrue("The sidebar label becomes visible before the gesture reaches its opening threshold", journalLabel.right > 0.dp)
        ui.onRoot().performTouchInput {
            advanceEventTime(200)
            up()
        }
        ui.onNodeWithTag("button.sidebar").assertIsDisplayed()
        ui.runOnIdle { assertTrue("A cancelled swipe is silent", hapticEvents.isEmpty()) }
        ui.onRoot().performTouchInput {
            swipeRight(startX = width * 0.08f, endX = width * 0.78f, durationMillis = 350)
        }
        ui.onNodeWithTag("link.sidebar.journals").assertIsDisplayed()
        assertEquals(initial, toolbar.getUnclippedBoundsInRoot())
        ui.onRoot().performTouchInput { click(Offset(width * 0.94f, height * 0.60f)) }
        ui.runOnIdle {
            assertEquals(listOf("open", "close"), events.filterIsInstance<LuiEvent.Extension>()
                .filter { it.identifier == "sidebar-overlay" }.map { it.name })
            assertEquals(listOf(HapticFeedbackType.SegmentTick, HapticFeedbackType.SegmentTick), hapticEvents)
        }
        ui.onNodeWithTag("button.sidebar").assertIsDisplayed().performTouchInput { click(center) }
        ui.onNodeWithTag("link.sidebar.journals").assertIsDisplayed()
        assertEquals(initial, toolbar.getUnclippedBoundsInRoot())
        val shell = ui.onNodeWithTag("application.shell").getUnclippedBoundsInRoot()
        val settings = ui.onNodeWithTag("button.sidebar.settings").assertIsDisplayed()
        val gear = settings.getUnclippedBoundsInRoot()
        assertTrue("Settings is in the bottom-right corner", shell.right - gear.right <= 24.dp &&
            shell.bottom - gear.bottom <= 24.dp)
        settings.performTouchInput { click(center) }
        ui.onNodeWithTag("screen.settings").assertIsDisplayed()
    }

    @Test fun sidebarScrollsAndDismissesFromThePanelAndBackdrop() {
        val recent = JSONArray().apply {
            repeat(40) { put(JSONObject().put("uuid", "recent-$it").put("title", "Recent page $it")) }
        }
        app(projection = JSONObject().put("recentPages", recent))
        ui.onRoot().performTouchInput {
            swipeRight(startX = width * 0.08f, endX = width * 0.78f, durationMillis = 350)
        }
        val backdrop = ui.onNodeWithTag("button.sidebar.dismiss").assertIsDisplayed()
        val row = ui.onNodeWithTag("link.sidebar.page.recent-0")
        val initialTop = row.getUnclippedBoundsInRoot().top
        backdrop.performTouchInput {
            swipe(Offset(centerX, height * 0.70f), Offset(centerX, height * 0.35f), durationMillis = 450)
        }
        val scrolledTop = row.getUnclippedBoundsInRoot().top
        assertTrue("Dragging on the backdrop scrolls the sidebar pages", scrolledTop < initialTop - 48.dp)
        val panelRight = backdrop.fetchSemanticsNode().boundsInRoot.left
        val panelEdge = panelRight - 2f
        ui.onRoot().performTouchInput {
            swipe(Offset(panelEdge, height * 0.30f), Offset(panelEdge, height * 0.65f), durationMillis = 450)
        }
        assertTrue("The panel's right edge also scrolls the sidebar pages",
            row.getUnclippedBoundsInRoot().top > scrolledTop + 48.dp)
        backdrop.performTouchInput {
            swipe(Offset(width * 0.90f, centerY), Offset(width * 0.15f, centerY), durationMillis = 300)
        }
        backdrop.assertIsDisplayed()
        ui.onRoot().performTouchInput {
            swipe(Offset(panelEdge, centerY), Offset(panelRight * 0.15f, centerY), durationMillis = 300)
        }
        backdrop.assertDoesNotExist()
        ui.onNodeWithTag("button.sidebar").assertIsDisplayed().performClick()
        backdrop.assertIsDisplayed()
        ui.onRoot().performTouchInput {
            swipe(Offset(width * 0.96f, centerY), Offset(width * 0.15f, centerY), durationMillis = 350)
        }
        backdrop.assertDoesNotExist()
        ui.onNodeWithTag("button.sidebar").assertIsDisplayed().performClick()
        backdrop.performTouchInput { click(center) }
        backdrop.assertDoesNotExist()
        ui.onNodeWithTag("button.sidebar").assertIsDisplayed()
    }

    @Test fun graphSwitchIsOnlyInTheJournalsHeader() {
        val graphs = JSONArray()
            .put(JSONObject().put("id", "review-layout").put("name", "Review graph").put("isReady", true))
            .put(JSONObject().put("id", "preparing").put("name", "Preparing graph").put("isReady", false))
        app(projection = JSONObject().put("graphs", graphs))
        val graphSwitch = hasTestTag("button.graph-switch")
        ui.onNode(graphSwitch and hasAnyAncestor(hasTestTag("header.main")))
            .assertIsDisplayed().performTouchInput { click(center) }
        ui.onNodeWithTag("menu.graph.review-layout").assertIsDisplayed()
        ui.onNodeWithTag("menu.graph.preparing").assertIsNotEnabled()
        pressBack()
        ui.onNodeWithTag("button.sidebar").performClick()
        ui.onNode(graphSwitch and hasAnyAncestor(hasTestTag("sidebar.navigation"))).assertDoesNotExist()
        ui.onNodeWithTag("link.sidebar.graphs").performClick()
        ui.onNodeWithTag("button.graph-switch").assertDoesNotExist()
    }

    @Test fun sidebarSettingsAndRowsSlideTogether() {
        app()
        val journals = ui.onNodeWithTag("link.sidebar.journals")
        val settings = ui.onNodeWithTag("button.sidebar.settings")
        ui.mainClock.autoAdvance = false
        try {
            ui.onNodeWithTag("button.sidebar").performClick()
            ui.mainClock.advanceTimeBy(96)
            val movingJournals = journals.getUnclippedBoundsInRoot().left
            val movingSettings = settings.getUnclippedBoundsInRoot().left
            ui.mainClock.advanceTimeBy(700)
            val journalTravel = journals.getUnclippedBoundsInRoot().left - movingJournals
            val settingsTravel = settings.getUnclippedBoundsInRoot().left - movingSettings
            assertTrue("The sidebar was in motion when sampled", journalTravel > 1.dp)
            val travelDifference = journalTravel - settingsTravel
            assertTrue("Settings and the sidebar rows travel together", travelDifference >= (-1).dp && travelDifference <= 1.dp)
        } finally {
            ui.mainClock.autoAdvance = true
        }
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
