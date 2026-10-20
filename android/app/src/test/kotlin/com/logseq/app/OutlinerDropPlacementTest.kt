package com.logseq.app

import com.logseq.app.ui.extensions.outlinerDropPlacement
import org.junit.Assert.assertEquals
import org.junit.Test

class OutlinerDropPlacementTest {
    @Test fun droppingNearTheTopInsertsBeforeEvenWhenIndented() {
        assertEquals("before", outlinerDropPlacement(5f, 100f, 150f))
    }

    @Test fun droppingOnTheLeftCreatesASibling() {
        assertEquals("after", outlinerDropPlacement(50f, 100f, 10f))
        assertEquals("after", outlinerDropPlacement(90f, 100f, 10f))
    }

    @Test fun draggingRightNestsTheBlock() {
        assertEquals("inside", outlinerDropPlacement(50f, 100f, 101f))
        assertEquals("inside", outlinerDropPlacement(90f, 100f, 101f))
    }

    @Test fun longBlocksKeepACompactInsertionZone() {
        assertEquals("before", outlinerDropPlacement(15f, 400f))
        assertEquals("after", outlinerDropPlacement(16f, 400f))
    }

    @Test fun shortBlocksAndZeroHeightUseSafeBoundaries() {
        assertEquals("before", outlinerDropPlacement(1f, 8f))
        assertEquals("after", outlinerDropPlacement(2f, 8f))
        assertEquals("before", outlinerDropPlacement(0f, 0f))
    }
}
