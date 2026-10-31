package com.logseq.app.ui.extensions

import androidx.pdf.PdfRect
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PdfAnnotationGeometryTest {
    @Test fun nativeSelectionKeepsTextAndDesktopCoordinates() {
        val highlight = encodePdfHighlight("annotation", 1, 600, 800, "Selected 原文",
            listOf(PdfRect(0, 20f, 30f, 180f, 50f)), "purple")
        assertEquals("Selected 原文", highlight.getJSONObject("content").getString("text"))
        assertEquals(1, highlight.getInt("page"))
        val rect = highlight.getJSONObject("position").getJSONArray("rects").getJSONObject(0)
        assertEquals(600.0, rect.getDouble("width"), 0.001)
        assertEquals(20.0, rect.getDouble("x1"), 0.001)
        assertEquals(50.0, rect.getDouble("y2"), 0.001)
    }

    @Test fun desktopHighlightsScaleToNativePagePoints() {
        val stored = JSONObject("""{"x1":40,"y1":60,"x2":360,"y2":100,"width":1200,"height":1600}""")
        val native = decodePdfRect(stored, 2, 600, 800)!!
        assertEquals(PdfRect(1, 20f, 30f, 180f, 50f), native)
    }

    @Test fun invalidSelectionCannotProduceAnAnnotation() {
        assertThrows(IllegalArgumentException::class.java) {
            encodePdfHighlight("annotation", 1, 600, 800, "", emptyList(), "yellow")
        }
        assertThrows(IllegalArgumentException::class.java) {
            encodePdfHighlight("annotation", 1, 0, 800, "Text", listOf(PdfRect(0, 0f, 0f, 10f, 10f)), "yellow")
        }
        assertEquals(null, decodePdfRect(JSONObject("""{"width":0,"height":0}"""), 1, 600, 800))
    }
}
