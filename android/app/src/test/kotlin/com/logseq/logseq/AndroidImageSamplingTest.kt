package com.logseq.logseq

import com.logseq.logseq.ui.extensions.bitmapSampleSize
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidImageSamplingTest {
    @Test fun largeImagesAreDecodedNearTheDisplayBound() {
        assertEquals(1, bitmapSampleSize(1600, 1200))
        assertEquals(2, bitmapSampleSize(4096, 2048))
        assertEquals(4, bitmapSampleSize(8192, 6000))
    }
}
