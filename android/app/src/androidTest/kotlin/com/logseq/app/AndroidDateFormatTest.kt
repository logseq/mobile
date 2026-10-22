package com.logseq.app

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONObject
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidDateFormatTest {
    @get:Rule val ui = createComposeRule()
    private lateinit var bridge: LogseqNativeBridge
    private lateinit var filter: LuiPatchFilter

    @After fun closeBridge() { if (::bridge.isInitialized) ui.runOnIdle { bridge.close() } }

    private fun snapshot(graph: String, format: String?): String = JSONObject().put("ok", true)
        .put("result", JSONObject().put("selectedGraphId", graph).put("graphName", graph)
            .apply { if (format != null) put("journalTitleFormat", format) }).toString()

    @Test fun dateFormatIsAbsentWhileEditorSettingsRemainAvailable() {
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, bridge) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        filter = LuiPatchFilter(backend)
        bridge = LogseqNativeBridge(onPatch = { if (it.isNotEmpty()) filter.applyJson(it) })
        val root = bridge.initialize(authenticationCode = 3)
        filter.applyJson(bridge.applySnapshot(snapshot("demo", "yyyy-MM-dd")))
        bridge.applyHostUpdate("graph-loading", "false").takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        bridge.applyHostUpdate("restore-ui-session", """{"graphId":"demo","destination":"journals","assets":[],"composerExpanded":false,"searchOpen":false,"query":"","appPath":[],"searchPath":[],"selectedPageId":null,"settingsOpen":true,"recentGraphIds":[]}""")
            .takeIf { it.isNotEmpty() }?.let(filter::applyJson)
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.darkScheme, typography = LogseqTheme.typography) {
                Surface(Modifier.fillMaxSize(), color = LogseqTheme.darkScheme.background) { backend.Content(root) }
            }
        }
        ui.onNodeWithTag("picker.settings.date-format").assertDoesNotExist()
        ui.onNodeWithText("Date format").assertDoesNotExist()
        ui.onNodeWithTag("switch.settings.spell-check").assertIsDisplayed()
        ui.runOnIdle { bridge.applySnapshot(snapshot("other", null)).takeIf { it.isNotEmpty() }?.let(filter::applyJson) }
        ui.onNodeWithTag("picker.settings.date-format").assertDoesNotExist()
        ui.onNodeWithText("MMM do, yyyy").assertDoesNotExist()
    }
}
