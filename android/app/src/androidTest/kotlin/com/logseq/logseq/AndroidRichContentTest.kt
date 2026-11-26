package com.logseq.logseq

import android.content.ClipboardManager
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
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
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.logseq.ui.LogseqTheme
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import java.io.File
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
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp

@RunWith(AndroidJUnit4::class)
class AndroidRichContentTest {
    @get:Rule val ui = createComposeRule()
    private val events = mutableListOf<LuiEvent>()

    private fun render(markup: String, completed: Boolean = false, secondMarkup: String? = null,
        linkColor: Color? = null, dark: Boolean = false, imagePath: String? = null,
        rowActions: JSONObject? = null,
        scrollState: ScrollState? = null,
        swipable: Boolean = false,
        onOpenImage: ((String, String) -> Unit)? = null,
        haptics: HapticFeedback? = null): LuiBackend {
        val registry = logseqExtensionRegistry(onOpenImage = onOpenImage)
        val backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val ops = JSONArray()
            .put(JSONObject().put("op", "create-node").put("id", 1).put("kind", if (secondMarkup == null) "root" else "column"))
            .put(JSONObject().put("op", "create-extension").put("id", 2)
                .put("identifier", "outliner-block-content")
                .put("fingerprint", registry.registration("outliner-block-content")!!.fingerprint))
        val parent = if (swipable) {
            val identifier = "outliner-row-swipe"
            ops.put(JSONObject().put("op", "create-extension").put("id", 4)
                .put("identifier", identifier).put("fingerprint", registry.registration(identifier)!!.fingerprint))
                .put(property("block-id", "rich-block").put("id", 4))
                .put(property("enabled", true).put("id", 4))
                .put(property("marker-inset", 0).put("id", 4))
                .put(JSONObject().put("op", "create-node").put("id", 5).put("kind", "box"))
                .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 4).put("index", 0))
                .put(JSONObject().put("op", "insert-child").put("parent", 4).put("child", 5).put("index", 0))
            5
        } else 1
        ops.put(JSONObject().put("op", "insert-child").put("parent", parent).put("child", 2).put("index", 0))
        mapOf(
            "block-id" to "rich-block", "title" to "Readable fallback", "markup-json" to markup,
            "is-completed" to completed, "is-asset" to (imagePath != null),
            "asset-type" to (if (imagePath != null) "png" else ""),
            "local-path" to imagePath.orEmpty(), "youtube-target-url" to "",
        ).forEach { (key, value) -> ops.put(property(key, value)) }
        rowActions?.let { ops.put(property("row-actions", it.toString())) }
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
                CompositionLocalProvider(
                    LocalLuiSemanticColors provides (linkColor?.let { mapOf("link" to it) } ?: emptyMap()),
                    LocalHapticFeedback provides (haptics ?: LocalHapticFeedback.current),
                ) {
                    if (scrollState == null) {
                        Box(Modifier.fillMaxSize()) { backend.Content(1) }
                    } else {
                        Column(Modifier.fillMaxSize().verticalScroll(scrollState)) {
                            Spacer(Modifier.height(80.dp))
                            backend.Content(1)
                            Spacer(Modifier.height(1200.dp))
                        }
                    }
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

    @Test fun longPressOnTaskOpensMenuWithoutEnteringSelection() {
        val feedback = mutableListOf<HapticFeedbackType>()
        render("""[{"type":"text","text":"Task block"}]""", rowActions = JSONObject().put("isTask", true),
            haptics = object : HapticFeedback {
                override fun performHapticFeedback(hapticFeedbackType: HapticFeedbackType) {
                    feedback += hapticFeedbackType
                }
            })
        ui.onNodeWithTag("outliner-block-content-rich-block").performTouchInput { longClick() }
        ui.onNodeWithTag("outliner.block.menu").assertIsDisplayed()
        ui.onNodeWithText("Deadline").assertIsDisplayed()
        ui.runOnIdle {
            assertTrue(events.filterIsInstance<LuiEvent.Extension>().isEmpty())
            assertEquals(listOf(HapticFeedbackType.LongPress), feedback)
        }
        ui.onNodeWithText("Scheduled").performClick()
        ui.runOnIdle {
            assertEquals(listOf("menu-action"), events.filterIsInstance<LuiEvent.Extension>().map { it.name })
        }
    }

    @Test fun draggingBlocksUsesTheDownAndReleasePositions() {
        render(
            """[{"type":"text","text":"Move this block"}]""",
            secondMarkup = """[{"type":"text","text":"Drop target"}]""",
            rowActions = JSONObject().put("isTask", false),
            scrollState = ScrollState(0),
        )
        val origin = ui.onNodeWithTag("outliner-block-content-rich-block").fetchSemanticsNode().boundsInWindow.center
        val target = ui.onNodeWithTag("outliner-block-content-timestamp-block").fetchSemanticsNode().boundsInWindow
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation

        fun dragTo(drop: Offset, expected: String) {
            ui.runOnIdle { events.clear() }
            val downAt = SystemClock.uptimeMillis()
            fun send(action: Int, point: Offset) {
                val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), action, point.x, point.y, 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                try {
                    check(automation.injectInputEvent(event, true)) { "Could not send action $action at $point" }
                } finally { event.recycle() }
            }
            send(MotionEvent.ACTION_DOWN, origin)
            val holdDuration = ViewConfiguration.getLongPressTimeout() + 100L
            ui.mainClock.advanceTimeBy(holdDuration)
            SystemClock.sleep(holdDuration)
            // Pass through the same point for both drags. Only the final release should determine nesting.
            val middle = Offset(target.center.x + target.width / 4, target.center.y)
            send(MotionEvent.ACTION_MOVE, middle)
            SystemClock.sleep(140)
            send(MotionEvent.ACTION_MOVE, middle)
            SystemClock.sleep(140)
            send(MotionEvent.ACTION_MOVE, drop)
            ui.onNodeWithTag("outliner.drop.$expected").assertIsDisplayed()
            SystemClock.sleep(400)
            send(MotionEvent.ACTION_UP, drop)
            ui.runOnIdle {
                assertTrue("The drag must lift the source at $origin, got $events",
                    events.filterIsInstance<LuiEvent.Extension>().any { it.name == "drag-start" })
            }
            ui.waitUntil(5_000) { ui.runOnIdle { events.filterIsInstance<LuiEvent.Extension>().any { it.name == "drop" } } }
            ui.runOnIdle {
                val gestures = events.filterIsInstance<LuiEvent.Extension>()
                    .filter { it.name == "drag-start" || it.name == "drop" }
                assertEquals(listOf("drag-start", "drop"), gestures.map { it.name })
                assertEquals("timestamp-block", gestures.last().values["uuid"])
                assertEquals(expected, gestures.last().values["placement"])
            }
        }

        dragTo(Offset(origin.x, target.center.y), "after")
        dragTo(Offset(origin.x + target.width / 4, target.center.y), "inside")
    }

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

    @Test fun inlineMathFitsTheParagraphAndInvalidTexRemainsReadable() {
        val wide = List(10) { "\\frac{1234567890}{9876543210}" }.joinToString("+")
        val invalid = "\\unknowncommand{" + "source must remain readable ".repeat(16).trimEnd() + "}"
        val prefix = "Before $wide after "
        val markup = JSONArray()
            .put(JSONObject().put("type", "text").put("text", "Before "))
            .put(JSONObject().put("type", "math").put("style", "inline").put("text", wide))
            .put(JSONObject().put("type", "text").put("text", " after "))
            .put(JSONObject().put("type", "math").put("style", "inline").put("text", invalid))
        render(markup.toString())
        ui.waitUntil(10_000) { ui.onAllNodesWithContentDescription(wide).fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithContentDescription(wide).assertIsDisplayed()
        val paragraph = layout(prefix + invalid)
        assertTrue(paragraph.placeholderRects.single()!!.width <= paragraph.size.width)
        val firstInvalidLine = paragraph.getLineForOffset(prefix.length)
        val lastInvalidLine = paragraph.getLineForOffset(prefix.length + invalid.lastIndex)
        assertTrue("The invalid LaTeX spans multiple lines", lastInvalidLine > firstInvalidLine)
        assertEquals(prefix.length + invalid.length, paragraph.getLineEnd(lastInvalidLine, visibleEnd = true))
    }

    @Test fun malformedBodyLongPressStillSelects() = assertLongPressSelects("not-json", "Readable fallback")

    @Test fun imageAssetLongPressSelectsAndShortTapOpensPreview() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("outliner-image", ".png", context.cacheDir)
        try {
            val bitmap = Bitmap.createBitmap(32, 18, Bitmap.Config.ARGB_8888)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()

            val previews = mutableListOf<Pair<String, String>>()
            render("[]", imagePath = file.path, onOpenImage = { uuid, path -> previews.add(uuid to path) })
            ui.waitUntil(5_000) { ui.onAllNodesWithTag("asset.preview.image").fetchSemanticsNodes().isNotEmpty() }
            val image = ui.onNodeWithTag("asset.preview.image").assertIsDisplayed()

            image.performTouchInput { longClick() }
            ui.runOnIdle {
                assertEquals(listOf("drag-start" to "rich-block"),
                    events.filterIsInstance<LuiEvent.Extension>().map { it.name to it.values["uuid"] })
                assertTrue(previews.isEmpty())
                events.clear()
            }

            image.performTouchInput { click() }
            ui.runOnIdle {
                assertEquals(listOf("rich-block" to file.path), previews)
                assertTrue(events.filterIsInstance<LuiEvent.Extension>().isEmpty())
            }
        } finally {
            file.delete()
        }
    }

    @Test fun imageBlockExposesItsMenuAsAnAccessibilityAction() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("image-menu", ".png", context.cacheDir)
        try {
            val bitmap = Bitmap.createBitmap(32, 18, Bitmap.Config.ARGB_8888)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            var previewed = false
            render("[]", rowActions = JSONObject().put("labels", JSONObject().put("More actions", "Image actions")),
                imagePath = file.path, onOpenImage = { _, _ -> previewed = true })
            ui.waitUntil(5_000) { ui.onAllNodesWithTag("asset.preview.image").fetchSemanticsNodes().isNotEmpty() }
            val image = ui.onNodeWithTag("asset.preview.image").assertIsDisplayed()
            assertEquals("Image actions", image.fetchSemanticsNode().config[SemanticsActions.OnLongClick].label)
            image.performSemanticsAction(SemanticsActions.OnLongClick) { assertTrue(it()) }
            ui.onNodeWithTag("outliner.block.menu").assertIsDisplayed()
            ui.runOnIdle { assertTrue(!previewed) }
        } finally {
            file.delete()
        }
    }

    @Test fun imageCopyWritesAReadableImageClip() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("copied-image", ".png", context.cacheDir)
        try {
            val bitmap = Bitmap.createBitmap(2, 3, Bitmap.Config.ARGB_8888)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            render("[]")
            ui.runOnIdle {
                val platform = AndroidPlatformServices(context)
                platform.copyImages(listOf(file.path), replacing = platform.clipboardTimestamp())
                val clipboard = context.getSystemService(ClipboardManager::class.java)
                val clip = requireNotNull(clipboard.primaryClip)
                assertTrue(clip.description.hasMimeType("image/png"))
                val item = clip.getItemAt(0)
                val contents = context.contentResolver.openInputStream(requireNotNull(item.uri))?.use { it.readBytes() }
                assertTrue(file.readBytes().contentEquals(contents))
                assertEquals(null, item.text)
            }
        } finally {
            file.delete()
        }
    }

    @Test fun shortBodyTapStillEditsExactlyOnce() {
        render("""[{"type":"text","text":"Tap to edit"}]""")
        ui.onNodeWithText("Tap to edit").performTouchInput { click() }
        ui.runOnIdle { assertEquals(listOf("edit"), events.filterIsInstance<LuiEvent.Extension>().map { it.name }) }
    }

    @Test fun onlyLeftSwipesToggleBlockSelection() {
        render("""[{"type":"text","text":"Selectable block"}]""", swipable = true)
        val block = ui.onNodeWithTag("outliner-block-content-rich-block")
        block.performTouchInput { swipeRight() }
        repeat(2) { block.performTouchInput { swipeLeft() } }
        ui.runOnIdle {
            assertEquals(List(2) { "toggle-selection" to "rich-block" },
                events.filterIsInstance<LuiEvent.Extension>().map { it.name to it.values["uuid"] })
        }
    }

    @Test fun diagonalLeftSwipeKeepsVerticalScrollAtRest() {
        val scroll = ScrollState(0)
        render("""[{"type":"text","text":"Selectable block"}]""", scrollState = scroll, swipable = true)
        val block = ui.onNodeWithTag("outliner-block-content-rich-block")
        block.performTouchInput {
            swipe(Offset(width * 0.8f, centerY), Offset(width * 0.2f, centerY - 52), durationMillis = 300)
        }
        ui.runOnIdle {
            assertEquals(0, scroll.value)
            assertEquals(listOf("toggle-selection"), events.filterIsInstance<LuiEvent.Extension>().map { it.name })
        }
        block.performTouchInput {
            swipe(center, Offset(centerX, centerY - 72), durationMillis = 300)
        }
        ui.runOnIdle { assertTrue(scroll.value > 0) }
    }

    @Test fun holdingALinkOnlyBlockEntersEditingInsteadOfOpeningIt() {
        render("""[{"type":"link","url":"https://logseq.com","children":[{"type":"text","text":"Website"}]}]""")
        ui.onNodeWithText("Website").performTouchInput { longClick() }
        ui.runOnIdle {
            assertEquals(
                "A link-only row must retain a reachable edit gesture",
                listOf("edit"),
                events.filterIsInstance<LuiEvent.Extension>().map { it.name },
            )
        }
    }

    @Test fun linkOnlyBlockMenuOffersEditInTheOutliner() {
        render("""[{"type":"link","url":"https://logseq.com","children":[{"type":"text","text":"Website"}]}]""",
            rowActions = JSONObject())
        ui.onNodeWithText("Website").performTouchInput { longClick() }
        ui.onNodeWithText("Edit").assertIsDisplayed().performClick()
        ui.runOnIdle {
            assertEquals(listOf("edit"), events.filterIsInstance<LuiEvent.Extension>().map { it.name })
        }
    }

    @Test fun shortTapStillOpensALinkOnlyBlockTarget() {
        render("""[{"type":"nodeReference","uuid":"page-target","title":"Destination"}]""", rowActions = JSONObject())
        val link = layout("[[Destination]]").getBoundingBox(3)
        ui.onNodeWithText("[[Destination]]").performTouchInput { click(link.center) }
        ui.runOnIdle {
            assertEquals(listOf("open-node" to "page-target"),
                events.filterIsInstance<LuiEvent.Extension>().map { it.name to it.values["uuid"] })
        }
    }

    @Test fun aMountedLinkOnlyBlockTapsToUnselectAfterASwipe() {
        val backend = render("""[{"type":"nodeReference","uuid":"page-target","title":"Destination"}]""",
            rowActions = JSONObject(), swipable = true)
        ui.onNodeWithTag("outliner-block-content-rich-block").assertIsDisplayed()
            .performTouchInput { swipeLeft() }
        ui.runOnIdle {
            assertEquals(listOf("toggle-selection"), events.filterIsInstance<LuiEvent.Extension>().map { it.name })
            events.clear()
            val actions = JSONObject().put("selectionMode", true).put("selectionMember", true)
            val update = JSONObject().put("generation", 2).put("ops", JSONArray().put(property("row-actions", actions.toString())))
            assertTrue(backend.lastError, backend.applyJson(update.toString()))
        }
        ui.onNodeWithText("[[Destination]]").performTouchInput { click() }
        ui.runOnIdle {
            assertEquals(listOf("toggle-selection" to "rich-block"),
                events.filterIsInstance<LuiEvent.Extension>().map { it.name to it.values["uuid"] })
        }
    }

    @Test fun calculatorSurfaceSwipesFromItsResult() {
        val registry = logseqExtensionRegistry()
        val backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val identifier = "outliner-row-swipe"
        val ops = JSONArray()
            .put(JSONObject().put("op", "create-node").put("id", 1).put("kind", "root"))
            .put(JSONObject().put("op", "create-extension").put("id", 2)
                .put("identifier", identifier).put("fingerprint", registry.registration(identifier)!!.fingerprint))
            .put(property("block-id", "calculator-block"))
            .put(property("enabled", true))
            .put(property("marker-inset", 0))
            .put(JSONObject().put("op", "create-node").put("id", 3).put("kind", "text"))
            .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 2).put("index", 0))
            .put(JSONObject().put("op", "insert-child").put("parent", 2).put("child", 3).put("index", 0))
            .put(JSONObject().put("op", "set-prop").put("id", 3).put("property", "text").put("value", "Result 42"))
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))
        ui.setContent { MaterialTheme { backend.Content(1) } }
        ui.onNodeWithText("Result 42").performTouchInput {
            swipe(Offset(width * 0.7f, centerY), Offset(-120f, centerY), durationMillis = 300)
        }
        ui.runOnIdle {
            assertEquals(listOf("toggle-selection" to "calculator-block"),
                events.filterIsInstance<LuiEvent.Extension>().map { it.name to it.values["uuid"] })
        }
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
