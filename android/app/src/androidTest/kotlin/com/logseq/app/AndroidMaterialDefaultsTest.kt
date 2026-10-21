package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertTouchHeightIsEqualTo
import androidx.compose.ui.test.assertTouchWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.logseqIconResolver
import dev.lui.LuiBackend
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidMaterialDefaultsTest {
    @get:Rule val ui = createComposeRule()
    private val typography = Typography().let {
        it.copy(bodyLarge = it.bodyLarge.copy(fontSize = 19.sp),
            titleMedium = it.titleMedium.copy(fontWeight = FontWeight.Light),
            bodyMedium = it.bodyMedium.copy(fontWeight = FontWeight.Normal),
            headlineLarge = it.headlineLarge.copy(fontSize = 37.sp))
    }
    private val scheme = lightColorScheme(primary = Color(0xFF1655A0), onSurface = Color(0xFF292A31))

    private fun render(kind: String, properties: Map<String, Any>, parentFont: String? = null) {
        val backend = LuiBackend(onEvent = {}, icons = logseqIconResolver)
        val ops = JSONArray().put(JSONObject().put("op", "create-node").put("id", 1).put("kind", "root"))
            .put(JSONObject().put("op", "create-node").put("id", 2).put("kind", kind))
        properties.forEach { (name, value) ->
            ops.put(JSONObject().put("op", "set-prop").put("id", 2).put("property", name).put("value", value))
        }
        if (parentFont != null) {
            ops.put(JSONObject().put("op", "create-node").put("id", 3).put("kind", "column"))
                .put(JSONObject().put("op", "set-prop").put("id", 3).put("property", "font-size").put("value", parentFont))
                .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 3).put("index", 0))
        }
        ops.put(JSONObject().put("op", "insert-child").put("parent", if (parentFont == null) 1 else 3).put("child", 2).put("index", 0))
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))
        ui.setContent {
            MaterialTheme(colorScheme = scheme, typography = typography) {
                Box(Modifier.fillMaxSize()) { backend.Content(1) }
            }
        }
    }

    private fun textLayout(): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        ui.onNodeWithText("Example").performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        return results.single()
    }

    @Test fun bodyUsesTheHostMaterialTypographyWithoutAnApplePointSizeOverride() {
        render("text", mapOf("text" to "Example"))
        assertEquals(typography.bodyLarge.fontSize, textLayout().layoutInput.style.fontSize)
    }

    @Test fun headingUsesTheHostMaterialRole() {
        render("heading", mapOf("text" to "Example", "heading-level" to 1))
        assertEquals(typography.headlineLarge.fontSize, textLayout().layoutInput.style.fontSize)
    }

    @Test fun semanticHeadlinePreservesTheMaterialRoleWeight() {
        render("text", mapOf("text" to "Example", "style-class" to "headline"))
        assertEquals(typography.titleMedium.fontWeight, textLayout().layoutInput.style.fontWeight)
    }

    @Test fun semanticSubheadlinePreservesTheMaterialRoleWeight() {
        render("text", mapOf("text" to "Example", "style-class" to "subheadline"))
        assertEquals(typography.bodyMedium.fontWeight, textLayout().layoutInput.style.fontWeight)
    }

    @Test fun explicitSemiboldStillOverridesTheMaterialRole() {
        render("text", mapOf("text" to "Example", "style-class" to "headline semibold"))
        assertEquals(FontWeight.SemiBold, textLayout().layoutInput.style.fontWeight)
    }

    @Test fun relativeFontSizeUsesTheMaterialBodySize() {
        render("text", mapOf("text" to "Example", "font-size" to "1.5rem"))
        assertEquals(28.5.sp, textLayout().layoutInput.style.fontSize)
    }

    @Test fun emFontSizeFollowsAnExplicitParentFont() {
        render("text", mapOf("text" to "Example", "font-size" to "1.5em"), parentFont = "24sp")
        assertEquals(36.sp, textLayout().layoutInput.style.fontSize)
    }

    @Test fun remFontSizeStaysRelativeToTheMaterialBodyUnderAStyledParent() {
        render("text", mapOf("text" to "Example", "font-size" to "1.5rem"), parentFont = "24sp")
        assertEquals(28.5.sp, textLayout().layoutInput.style.fontSize)
    }

    @Test fun sharedGlassTokenUsesAnOpaqueMaterialContainer() {
        render("text", mapOf("text" to "Example", "foreground" to "glass"))
        assertEquals(scheme.surfaceContainerHigh, textLayout().layoutInput.style.color)
    }

    @Test fun composerInputUsesTheHostMaterialBodyRole() {
        render("textarea", mapOf("text" to "Example", "style-class" to "composer-input"))
        assertEquals(typography.bodyLarge.fontSize, textLayout().layoutInput.style.fontSize)
    }

    @Test fun explicitFontSizesStillOverrideMaterialDefaults() {
        render("text", mapOf("text" to "Example", "font-size" to "25sp"))
        assertEquals(25.sp, textLayout().layoutInput.style.fontSize)
    }

    @Test fun textButtonUsesTheMaterialPrimaryColorByDefault() {
        render("button", mapOf("text" to "Example", "variant" to "ghost"))
        assertEquals(scheme.primary, textLayout().layoutInput.style.color)
    }

    @Test fun explicitButtonForegroundIsPreserved() {
        render("button", mapOf("text" to "Example", "variant" to "ghost", "foreground" to "#e01020"))
        assertEquals(Color(0xFFE01020), textLayout().layoutInput.style.color)
    }

    @Test fun iconButtonsHaveNativeButtonSemanticsAndMinimumTouchTargets() {
        render("button", mapOf("icon" to "app:composer-add", "variant" to "ghost", "accessibility-label" to "Example"))
        ui.onNodeWithContentDescription("Example")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertTouchHeightIsEqualTo(48.dp).assertTouchWidthIsEqualTo(48.dp)
    }
}
