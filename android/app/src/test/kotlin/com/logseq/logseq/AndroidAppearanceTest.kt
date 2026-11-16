package com.logseq.logseq

import android.content.res.Configuration
import com.logseq.logseq.ui.extensions.themedHtmlContent
import org.junit.Assert.*
import org.junit.Test

class AndroidAppearanceTest {
    @Test fun explicitAppearanceWinsOverSystemAndSystemModeRemainsAdaptive() {
        for (night in listOf(Configuration.UI_MODE_NIGHT_NO, Configuration.UI_MODE_NIGHT_YES)) {
            val configuration = Configuration().apply { uiMode = Configuration.UI_MODE_TYPE_NORMAL or night }
            assertTrue(androidAppearanceIsDark("dark", configuration))
            assertFalse(androidAppearanceIsDark("light", configuration))
            assertEquals(night == Configuration.UI_MODE_NIGHT_YES,
                androidAppearanceIsDark("system", configuration))
        }
    }

    @Test fun htmlTracksTheAppPaletteRatherThanTheWebViewsSystemTheme() {
        val html = "<p>Readable</p><a href='https://example.com'>Link</a>"
        val dark = themedHtmlContent(html, true, 0xffe6e1e5.toInt(), 0xff9bd3d4.toInt())
        assertTrue(dark.contains("color-scheme:dark"))
        assertTrue(dark.contains("color:#e6e1e5"))
        assertTrue(dark.contains("a{color:#9bd3d4}"))
        assertTrue(dark.endsWith(html))
        val light = themedHtmlContent(html, false, 0xff1c1b1f.toInt(), 0xff1b6898.toInt())
        assertTrue(light.contains("color-scheme:light"))
        assertTrue(light.contains("color:#1c1b1f"))
        assertNotEquals(dark, light)
    }
}
