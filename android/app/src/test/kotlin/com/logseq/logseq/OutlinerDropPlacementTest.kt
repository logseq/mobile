package com.logseq.logseq

import com.logseq.logseq.ui.extensions.outlinerDropPlacement
import org.junit.Assert.assertEquals
import org.junit.Test

class OutlinerDropPlacementTest {
    @Test fun droppingNearTheTopInsertsBeforeEvenWhenIndented() {
        assertEquals("before", outlinerDropPlacement(5f, 100f, 150f, 40f))
    }

    @Test fun droppingOnTheLeftCreatesASibling() {
        assertEquals("after", outlinerDropPlacement(50f, 100f, 10f, 40f))
        assertEquals("after", outlinerDropPlacement(90f, 100f, 10f, 0f))
    }

    @Test fun draggingRightNestsTheBlock() {
        assertEquals("inside", outlinerDropPlacement(50f, 100f, 101f, 22f))
        assertEquals("inside", outlinerDropPlacement(90f, 100f, 101f, 50f))
    }

    @Test fun aRightSideStartDoesNotNestWithoutAFullRightwardMove() {
        assertEquals("after", outlinerDropPlacement(50f, 100f, 150f, 0f))
        assertEquals("after", outlinerDropPlacement(50f, 100f, 150f, 21f))
        assertEquals("after", outlinerDropPlacement(50f, 100f, 150f, -30f))
    }

    @Test fun longBlocksKeepACompactInsertionZone() {
        assertEquals("before", outlinerDropPlacement(15f, 400f, 0f, 0f))
        assertEquals("after", outlinerDropPlacement(16f, 400f, 0f, 0f))
    }

    @Test fun shortBlocksAndZeroHeightUseSafeBoundaries() {
        assertEquals("before", outlinerDropPlacement(1f, 8f, 0f, 0f))
        assertEquals("after", outlinerDropPlacement(2f, 8f, 0f, 0f))
        assertEquals("before", outlinerDropPlacement(0f, 0f, 0f, 0f))
    }
}
