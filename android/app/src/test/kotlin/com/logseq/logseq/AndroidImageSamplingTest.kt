package com.logseq.logseq

import com.logseq.logseq.ui.extensions.bitmapSampleSize
import com.logseq.logseq.ui.extensions.isLinkOnlyMarkup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidImageSamplingTest {
    @Test fun largeImagesAreDecodedNearTheDisplayBound() {
        assertEquals(1, bitmapSampleSize(1600, 1200))
        assertEquals(2, bitmapSampleSize(4096, 2048))
        assertEquals(4, bitmapSampleSize(8192, 6000))
    }

    @Test fun onlyAStandaloneLinkReservesLongPressForEditing() {
        assertTrue(isLinkOnlyMarkup("""[{"type":"nodeReference","uuid":"page"}]"""))
        assertTrue(isLinkOnlyMarkup("""[{"type":"url","url":"https://example.com"}]"""))
        assertFalse(isLinkOnlyMarkup("""[{"type":"text","text":"See "},{"type":"nodeReference","uuid":"page"}]"""))
    }
}
