package com.logseq.app

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.luminance
import androidx.compose.material3.ColorScheme
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.ui.LogseqTheme
import com.logseq.app.ui.extensions.AndroidCodeBlock
import com.logseq.app.ui.extensions.AndroidMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidMathCodeTest {
    @get:Rule val ui = createComposeRule()

    private fun awaitFormula(source: String) {
        ui.waitUntil(10_000) {
            ui.onAllNodesWithContentDescription(source).fetchSemanticsNodes().isNotEmpty()
        }
        ui.onNodeWithContentDescription(source).assertIsDisplayed()
    }

    private fun layout(source: String): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        ui.onNodeWithText(source).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        return results.single()
    }

    private fun awaitHighlight(source: String): TextLayoutResult {
        ui.waitUntil(10_000) { layout(source).layoutInput.text.spanStyles.isNotEmpty() }
        return layout(source)
    }

    @Test fun formulasLayOutFractionsAndSuperscriptsInsteadOfPrintingTex() {
        val fraction = "\\frac{1}{\\sqrt{x^2+1}}"
        ui.setContent {
            MaterialTheme { Column { AndroidMath("x"); AndroidMath(fraction) } }
        }
        awaitFormula("x")
        awaitFormula(fraction)
        ui.onNodeWithText(fraction).assertDoesNotExist()
        val simple = ui.onNodeWithContentDescription("x").fetchSemanticsNode().boundsInRoot
        val stacked = ui.onNodeWithContentDescription(fraction).fetchSemanticsNode().boundsInRoot
        assertTrue("Fraction occupies real stacked layout", stacked.height > simple.height * 1.5f)
        val pixels = ui.onNodeWithContentDescription(fraction).captureToImage().toPixelMap()
        var ink = 0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            if (pixels[x, y].red < .5f && pixels[x, y].green < .5f && pixels[x, y].blue < .5f) ink++
        }
        assertTrue("Formula contains rendered strokes", ink > 50)
    }

    @Test fun invalidAndEmptyFormulaStayReadableWithoutBreakingValidNeighbor() {
        val invalid = "\\unknowncommand{"
        ui.setContent { MaterialTheme { Column { AndroidMath(invalid); AndroidMath(""); AndroidMath("y^2") } } }
        awaitFormula("y^2")
        ui.onNodeWithText(invalid).assertIsDisplayed()
        ui.onNodeWithText("y^2").assertDoesNotExist()
    }

    @Test fun formulaRespondsToFontScaleAndDarkTheme() {
        val large = mutableStateOf(false)
        ui.setContent {
            val density = LocalDensity.current
            MaterialTheme(colorScheme = if (large.value) LogseqTheme.darkScheme else LogseqTheme.lightScheme) {
                CompositionLocalProvider(LocalDensity provides Density(density.density, if (large.value) 2f else 1f)) {
                    AndroidMath("x^2")
                }
            }
        }
        awaitFormula("x^2")
        val originalHeight = ui.onNodeWithContentDescription("x^2").fetchSemanticsNode().boundsInRoot.height
        ui.runOnIdle { large.value = true }
        ui.waitUntil(10_000) {
            ui.onAllNodesWithContentDescription("x^2").fetchSemanticsNodes().singleOrNull()
                ?.boundsInRoot?.height?.let { it > originalHeight * 1.7f } == true
        }
        val pixels = ui.onNodeWithContentDescription("x^2").captureToImage().toPixelMap()
        assertTrue("Dark theme uses visible light ink", (0 until pixels.height).any { y ->
            (0 until pixels.width).any { x -> pixels[x, y].let { it.red > .7f && it.green > .7f && it.blue > .7f && it.alpha > .8f } }
        })
    }

    @Test fun swiftCodeShowsLanguageAndDistinctKeywordLiteralAndCommentColors() {
        val code = "let answer = 42 // note\nprint(answer)"
        ui.setContent { MaterialTheme { AndroidCodeBlock(code, "swift") } }
        ui.onNodeWithText("swift").assertIsDisplayed()
        val annotated = awaitHighlight(code).layoutInput.text
        assertEquals(code, annotated.text)
        fun colorAt(offset: Int): Color = annotated.spanStyles.last { it.start <= offset && it.end > offset }.item.color
        assertTrue(colorAt(0) != colorAt(code.indexOf("42")))
        assertTrue(colorAt(0) != colorAt(code.indexOf("//")))
    }

    @Test fun unknownLanguageAndEmptyCodePreserveUnicodeAndWhitespace() {
        val code = "  中文 😀\tunchanged\n\n"
        ui.setContent { MaterialTheme { Column { AndroidCodeBlock(code, "custom-lang"); AndroidCodeBlock("", "") } } }
        ui.onNodeWithText("custom-lang").assertIsDisplayed()
        ui.onNodeWithText(code).assertIsDisplayed().assertTextEquals(code)
        assertEquals(code, layout(code).layoutInput.text.text)
    }

    @Test fun codeThemeAndSourceChangesInvalidateHighlighting() {
        val dark = mutableStateOf(false)
        val source = mutableStateOf("let value = 1")
        ui.setContent {
            MaterialTheme(colorScheme = if (dark.value) LogseqTheme.darkScheme else LogseqTheme.lightScheme) {
                AndroidCodeBlock(source.value, "swift")
            }
        }
        val before = awaitHighlight(source.value).layoutInput.text.spanStyles.first().item.color
        ui.runOnIdle { dark.value = true; source.value = "let value = 2" }
        val after = awaitHighlight(source.value).layoutInput.text.spanStyles.first().item.color
        assertTrue("Theme changes highlighted color", before != after)
        ui.onNodeWithText("let value = 1").assertDoesNotExist()
        ui.onNodeWithText("let value = 2").assertTextEquals("let value = 2")
    }

    private fun checkCodeContrast(scheme: ColorScheme) {
        val source = "let answer = 42 // note\nprint(\"hello\")"
        ui.setContent { MaterialTheme(colorScheme = scheme) { AndroidCodeBlock(source, "swift") } }
        val spans = awaitHighlight(source).layoutInput.text.spanStyles
        val background = scheme.surfaceContainerHigh.luminance()
        for (span in spans) {
            val color = span.item.color
            if (color == Color.Unspecified) continue
            val foreground = color.luminance()
            val contrast = (maxOf(foreground, background) + .05f) / (minOf(foreground, background) + .05f)
            assertTrue("Readable syntax color for ${source.substring(span.start, span.end)}: $contrast", contrast >= 4.5f)
        }
    }

    @Test fun lightCodeHighlightingHasReadableContrast() = checkCodeContrast(LogseqTheme.lightScheme)
    @Test fun darkCodeHighlightingHasReadableContrast() = checkCodeContrast(LogseqTheme.darkScheme)
}
