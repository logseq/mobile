package com.logseq.logseq

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.logseq.runtime.LogseqNativeBridge
import com.logseq.logseq.runtime.LuiPatchFilter
import com.logseq.logseq.runtime.dispatchLuiEvent
import com.logseq.logseq.runtime.logseqIconResolver
import com.logseq.logseq.ui.LogseqTheme
import com.logseq.logseq.ui.extensions.NavigationChromeLayout
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidNavigationChromeLayoutTest {
    @get:Rule val ui = createComposeRule()
    private var bridge: LogseqNativeBridge? = null

    @After fun closeBridge() { bridge?.let { ui.runOnIdle { it.close() } } }

    private fun checkChrome(occupies: Boolean) {
        ui.setContent {
            Box(Modifier.fillMaxSize().testTag("screen")) {
                NavigationChromeLayout(occupies,
                    content = { Box(Modifier.fillMaxSize().testTag("content")) },
                    chrome = {
                        // BoxWithConstraints rejects intrinsic measurement. Its
                        // child also models the chrome's vertical grow modifiers.
                        BoxWithConstraints(Modifier.fillMaxWidth()) {
                            Box(Modifier.fillMaxHeight().height(56.dp).testTag("chrome"))
                        }
                    })
            }
        }
        val screen = ui.onNodeWithTag("screen").getUnclippedBoundsInRoot()
        val content = ui.onNodeWithTag("content").getUnclippedBoundsInRoot()
        val chrome = ui.onNodeWithTag("chrome").getUnclippedBoundsInRoot()
        assertEquals(56f, (chrome.bottom - chrome.top).value, 1f)
        assertEquals(screen.bottom.value, chrome.bottom.value, 1f)
        assertEquals((if (occupies) chrome.top else screen.bottom).value, content.bottom.value, 1f)
    }

    @Test fun overlayChromeMeasuresSubcomposedContentAtNaturalHeight() = checkChrome(false)
    @Test fun insetChromeMeasuresSubcomposedContentAtNaturalHeight() = checkChrome(true)

    @Test fun captureChromeKeepsItsHeightAndOpensComposer() {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(onEvent = { dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it }, icons = logseqIconResolver)
        val filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        filter.applyJson(native.applySnapshot("""{"ok":true,"result":{
            "graphName":"Chrome layout test","selectedGraphId":"chrome-layout-test",
            "isGraphUnlocked":true,"outlinerRows":[]}}"""))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = LogseqTheme.lightScheme, typography = LogseqTheme.typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(root) }
            }
        }
        ui.onNodeWithTag("pane.journals").assertHeightIsAtLeast(120.dp)
        ui.onNodeWithTag("button.search").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        ui.onNodeWithTag("button.composer.expand").assertIsDisplayed().assertHeightIsAtLeast(48.dp).performClick()
        ui.onNodeWithTag("field.composer").assertIsDisplayed()
        ui.onNodeWithTag("button.send").assertIsDisplayed()
    }
}
