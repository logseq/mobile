package com.logseq.logseq

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.logseq.ui.extensions.NavigationChromeLayout
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidNavigationChromeLayoutTest {
    @get:Rule val ui = createComposeRule()

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
}
