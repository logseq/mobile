package com.logseq.logseq

import com.logseq.logseq.ui.extensions.sidebarSettlesOpen
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SidebarSwipeTest {
    @Test fun openingStaysOpenWhenThePanelIsVisibleAndVelocityWasLost() {
        assertTrue(sidebarSettlesOpen(position = 0.27f, velocity = 0f, revealed = 0.79f, opening = true))
    }

    @Test fun aFastFlickCanOpenBeforeTheRevealThreshold() {
        assertTrue(sidebarSettlesOpen(position = 0.2f, velocity = 2f, revealed = 0.67f, opening = true))
    }

    @Test fun aSmallDragOrReversingAnOpeningSwipeClosesThePanel() {
        assertFalse(sidebarSettlesOpen(position = 0.1f, velocity = 0f, revealed = 0.41f, opening = true))
        assertFalse(sidebarSettlesOpen(position = 0.3f, velocity = -1f, revealed = 0.83f, opening = true))
    }

    @Test fun aClosingFlickCanDismissAStillVisiblePanel() {
        assertFalse(sidebarSettlesOpen(position = 0.77f, velocity = -2f, revealed = 0.77f, opening = false))
    }

    @Test fun motionBackTowardOpenAtReleaseDoesNotUndoAClosingDrag() {
        assertFalse(sidebarSettlesOpen(position = 0.45f, velocity = 2f, revealed = 0.45f, opening = false))
        assertTrue(sidebarSettlesOpen(position = 0.55f, velocity = 2f, revealed = 0.55f, opening = false))
    }
}
