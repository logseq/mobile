package com.logseq.app.runtime

import org.junit.Assert.assertEquals
import org.junit.Test

class LuiDispatchTest {
    @Test
    fun viewportWidthCrossesTheNativeEventBoundary() {
        assertEquals(820L, extensionValue(mapOf("width" to 820)))
        assertEquals(393L, extensionValue(mapOf("width" to 393)))
    }
}
