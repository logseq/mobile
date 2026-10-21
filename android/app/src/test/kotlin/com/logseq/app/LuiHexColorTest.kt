package com.logseq.app

import androidx.compose.ui.graphics.Color
import dev.lui.luiHexColor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LuiHexColorTest {
    @Test fun opaqueRgbDoesNotRotateItsChannelsIntoAlpha() {
        assertEquals(Color(0xFFE01020), luiHexColor("#e01020"))
        assertEquals(Color(0xFF2255AA), luiHexColor("#25a"))
    }

    @Test fun cssAlphaRemainsAtTheEndForBothLengths() {
        assertEquals(Color(0x802255AA), luiHexColor("#2255aa80"))
        assertEquals(Color(0x882255AA), luiHexColor("#25a8"))
    }

    @Test fun invalidColorsAreRejected() {
        assertNull(luiHexColor("#qqqqqq"))
        assertNull(luiHexColor("#12"))
    }
}
