package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidNodePropertiesTest {
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge

    @After fun closeBridge() {
        if (::bridge.isInitialized) ui.runOnIdle { bridge.close() }
    }

    @Test fun historicalDatesCanBeOpenedTypedAndSelected() {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        val filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        val snapshot = JSONObject(InstrumentationRegistry.getInstrumentation().context.assets
            .open("node-properties.json").bufferedReader().use { it.readText() })
        val properties = snapshot.getJSONObject("result").getJSONObject("nodeProperties").getJSONArray("properties")
        for (i in 0 until properties.length()) {
            val property = properties.getJSONObject(i)
            if (property.getString("attr") == "user.property/Due") property.put("editorValue", "0044-03-15")
        }
        filter.applyJson(bridge.applySnapshot(snapshot.toString()))
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        ui.setContent { MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
            Box(Modifier.fillMaxSize()) { backend.Content(root) }
        } }
        ui.onNodeWithTag("properties.expand.page").performClick()
        val editor = "property.page.user.property/Due"
        ui.onNodeWithTag("property.value.page.user.property/Due").performScrollTo().performClick()
        fun input() = ui.onNodeWithTag("view.edit.date.input.$editor")
        input().assertTextEquals("0044-03-15")
        val calendar = hasAnyAncestor(hasTestTag("view.edit.date.$editor"))
        ui.onNode(hasText("March 15", substring = true) and calendar, useUnmergedTree = true).performScrollTo().performClick()
        input().assertTextEquals("0044-03-15")
        input().performTextReplacement("2026-10-26")
        closeSoftKeyboard()
        ui.onNode(hasText("October 23", substring = true) and calendar, useUnmergedTree = true).performScrollTo().performClick()
        input().assertTextEquals("2026-10-23")
        input().performTextReplacement("January 1, 2000")
        input().assertTextEquals("January 1, 2000")
        ui.onNodeWithTag("view.edit.save.$editor").performClick()
        ui.runOnIdle {
            var selected: JSONObject? = null
            repeat(32) {
                val encoded = bridge.takeEffect()
                if (encoded.isNotEmpty()) {
                    val effect = JSONObject(encoded).optJSONObject("effect")
                    if (effect?.optString("kind") == "node-property") selected = JSONObject(effect.getString("text"))
                }
            }
            assertEquals("Natural-language input reaches the shared core unchanged", "January 1, 2000", selected?.getString("value"))
        }
    }

    @Test fun pagePropertiesUseBlocksAndNativeTypedEditors() {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        val filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        val snapshot = InstrumentationRegistry.getInstrumentation().context.assets
            .open("node-properties.json").bufferedReader().use { it.readText() }
        filter.applyJson(bridge.applySnapshot(snapshot))
        val settingsPatch = bridge.applyHostUpdate("settings", """{"appearance":"dark","language":"en","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"https://api.logseq.io","version":"test","revision":"test"}""")
        settingsPatch.takeIf { it.isNotEmpty() }?.let { filter.applyJson(it) }
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let { filter.applyJson(it) }
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.darkScheme, typography = LogseqTheme.typography) {
                CompositionLocalProvider(dev.lui.LocalLuiThemeDark provides true) {
                    Surface(Modifier.fillMaxSize(), color = LogseqTheme.darkScheme.background) { backend.Content(root) }
                }
            }
        }
        ui.onNodeWithText("Summary").assertIsDisplayed()
        ui.onNodeWithTag("outliner.block.text-value").assertIsDisplayed()
        ui.onNodeWithTag("property.inline.page.user.property/Score").assertIsDisplayed()
        ui.onNodeWithText("A very long property name for this project").assertDoesNotExist()
        ui.onNodeWithTag("properties.expand.page").performClick()
        ui.onNodeWithText("A very long property name for this project").assertIsDisplayed()
        val shortLabels = listOf("Assignee", "Reproducible")
        for (attr in shortLabels) {
            val label = ui.onNodeWithTag("property.label.page.user.property/$attr").fetchSemanticsNode().boundsInRoot
            val value = ui.onNodeWithTag("property.value.page.user.property/$attr").fetchSemanticsNode().boundsInRoot
            assertTrue("Short labels remain on one line", label.height < value.height + 1)
            assertTrue("Short labels remain inline", kotlin.math.abs(label.center.y - value.center.y) < 16)
        }
        val referenceTags = listOf("property.value.page.user.property/Assignee",
            "property.value.page.user.property/Assignee.megayu", "property.value.page.user.property/Assignee.tienson")
        val references = referenceTags.map { ui.onNodeWithTag(it).fetchSemanticsNode().boundsInRoot }
        for ((left, right) in references.zipWithNext()) {
            assertTrue("Node values share a row", kotlin.math.abs(left.center.y - right.center.y) < 1)
            assertTrue("Node values retain their order", right.left >= left.right)
        }
        ui.onAllNodesWithText(", ").assertCountEquals(2)
        for (tag in referenceTags) {
            ui.onNodeWithTag(tag).performClick()
            ui.onNodeWithTag("view.edit.sheet.property.page.user.property/Assignee").assertIsDisplayed()
            ui.onNodeWithTag("view.edit.cancel.property.page.user.property/Assignee").performClick()
        }
        val longLabel = ui.onNodeWithTag("property.label.page.user.property/Long").fetchSemanticsNode().boundsInRoot
        val longValue = ui.onNodeWithTag("property.value.page.user.property/Long").fetchSemanticsNode().boundsInRoot
        assertTrue("Long labels place the value on the next line", longValue.top >= longLabel.bottom)
        ui.onNodeWithText("Property breadcrumb must stay hidden").assertDoesNotExist()
        val screen = ui.onRoot().captureToImage().asAndroidBitmap()
        val directory = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("qa"))
        directory.mkdirs()
        directory.resolve("properties-dark.png").outputStream().use {
            screen.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        assertEquals("The property surface follows the Android host dark appearance", 0x101318,
            screen.getPixel(10, screen.height / 2) and 0xFFFFFF)
        val bitmap = ui.onNodeWithTag("property.value.page.user.property/Ready").captureToImage().asAndroidBitmap()
        var blue = 0
        for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
            val pixel = bitmap.getPixel(x, y)
            val r = android.graphics.Color.red(pixel)
            val g = android.graphics.Color.green(pixel)
            val b = android.graphics.Color.blue(pixel)
            if (b > r + 30 && b > g + 20) blue++
        }
        assertEquals("Property checkboxes must use a subdued foreground", 0, blue)
        ui.onNodeWithTag("property.value.page.user.property/Ready").performClick()
        ui.onNodeWithTag("property.value.page.user.property/Ready").assertIsOff()
        ui.runOnIdle {
            var payload: JSONObject? = null
            repeat(32) {
                val encoded = bridge.takeEffect()
                if (encoded.isNotEmpty()) {
                    val effect = JSONObject(encoded).optJSONObject("effect")
                    if (effect?.optString("kind") == "node-property") payload = JSONObject(effect.getString("text"))
                }
            }
            assertTrue("Property edits must cross the real native bridge", payload != null)
            assertEquals("page", payload!!.getString("blockUuid"))
            assertEquals("user.property/Ready", payload!!.getString("attr"))
            assertEquals("false", payload!!.getString("value"))
        }
        for (attr in listOf("Due", "Deadline")) {
            ui.onNodeWithTag("property.value.page.user.property/$attr").performScrollTo().performClick()
            ui.onNodeWithTag("view.edit.date.property.page.user.property/$attr", useUnmergedTree = true).assertIsDisplayed()
            ui.onNodeWithText("October 23", substring = true, useUnmergedTree = true).performScrollTo().performClick()
            ui.onNodeWithTag("view.edit.save.property.page.user.property/$attr").performClick()
            ui.runOnIdle {
                var selected: JSONObject? = null
                repeat(32) {
                    val encoded = bridge.takeEffect()
                    if (encoded.isNotEmpty()) {
                        val effect = JSONObject(encoded).optJSONObject("effect")
                        if (effect?.optString("kind") == "node-property") selected = JSONObject(effect.getString("text"))
                    }
                }
                assertTrue("A native picker submits its selection", selected != null)
                val value = selected!!.getString("value")
                if (attr == "Due") assertEquals("2026-10-23", value)
                else assertEquals(java.time.LocalDate.of(2026, 10, 23), java.time.Instant.ofEpochMilli(value.toLong())
                    .atZone(java.time.ZoneId.systemDefault()).toLocalDate())
            }
            ui.onNodeWithTag("view.edit.cancel.property.page.user.property/$attr").performClick()
        }
    }
}
