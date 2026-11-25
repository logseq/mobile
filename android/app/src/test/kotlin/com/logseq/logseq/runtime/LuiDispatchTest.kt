package com.logseq.logseq.runtime

import org.junit.Assert.assertEquals
import org.junit.Test

class LuiDispatchTest {
    @Test
    fun viewportWidthCrossesTheNativeEventBoundary() {
        assertEquals(820L, extensionValue(mapOf("width" to 820)))
        assertEquals(393L, extensionValue(mapOf("width" to 393)))
    }

    @Test
    fun bottomTabIndexCrossesTheNativeEventBoundary() {
        assertEquals(3L, extensionValue(mapOf("index" to 3)))
    }
}
