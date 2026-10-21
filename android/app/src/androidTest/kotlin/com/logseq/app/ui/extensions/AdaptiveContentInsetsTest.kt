package com.logseq.app.ui.extensions

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class AdaptiveContentInsetsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun contentRespondsToAvailableWidthWithoutChangingCompactInsets() {
        val width = mutableFloatStateOf(393f)
        var measuredWidth = -1f
        compose.setContent {
            val density = LocalDensity.current.density
            Box(Modifier.requiredWidth(width.floatValue.dp)) {
                AdaptiveContentInsets(breakpoint = 600, wideInset = 16) {
                    Box(Modifier.fillMaxSize().onSizeChanged { measuredWidth = it.width / density })
                }
            }
        }
        for ((available, expected) in listOf(393f to 393f, 599f to 599f, 600f to 568f,
                                            820f to 788f, 1180f to 1148f, 500f to 500f)) {
            compose.runOnIdle { width.floatValue = available }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals("available width $available", expected, measuredWidth, 0.6f) }
        }
    }
}
