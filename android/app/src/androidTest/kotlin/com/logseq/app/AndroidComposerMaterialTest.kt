package com.logseq.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertTouchHeightIsEqualTo
import androidx.compose.ui.test.assertTouchWidthIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.runtime.dispatchLuiEvent
import com.logseq.app.runtime.logseqIconResolver
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidComposerMaterialTest {
    @get:Rule val ui = createComposeRule()
    private var bridge: LogseqNativeBridge? = null
    private val primary = Color(0xFF1655A0)
    private val secondaryContainer = Color(0xFFDCEAF6)
    private val surfaceContainerLow = Color(0xFFEAF1ED)

    @After fun closeBridge() { bridge?.let { ui.runOnIdle { it.close() } } }

    private fun composer(expanded: Boolean = true) {
        lateinit var native: LogseqNativeBridge
        val backend = LuiBackend(
            onEvent = { dispatchLuiEvent(it, native) },
            extensions = logseqExtensionRegistry { it },
            icons = logseqIconResolver,
        )
        val filter = LuiPatchFilter(backend)
        native = LogseqNativeBridge(onPatch = { filter.applyJson(it) })
        bridge = native
        val root = native.initialize(authenticationCode = 3)
        filter.applyJson(native.applySnapshot("""{"ok":true,"result":{
            "graphName":"Composer material test","selectedGraphId":"composer-material-test",
            "isGraphUnlocked":true,"outlinerRows":[]}}"""))
        ui.setContent {
            MaterialExpressiveTheme(colorScheme = lightColorScheme(primary = primary,
                secondaryContainer = secondaryContainer, surfaceContainerLow = surfaceContainerLow)) {
                Box(Modifier.fillMaxSize().background(Color.Red)) { backend.Content(root) }
            }
        }
        if (expanded) ui.onNodeWithTag("button.composer.expand").performClick()
    }

    @Test fun emptyInputHasTheNativeMaterialFieldHeight() {
        composer()
        ui.onNodeWithTag("field.composer").assertHeightIsAtLeast(56.dp)
    }

    @Test fun enabledSendUsesTheHostMaterialPrimaryContainer() {
        composer()
        ui.onNodeWithTag("field.composer").performTextInput("Unsent 中文")
        val pixels = ui.onNodeWithTag("button.send").captureToImage().toPixelMap()
        var primaryPixels = 0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            if (pixels[x, y] == primary) primaryPixels++
        }
        assertTrue("Send uses the host Material primary color", primaryPixels > pixels.width * pixels.height / 4)
        ui.onNodeWithTag("button.send")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertTouchHeightIsEqualTo(48.dp).assertTouchWidthIsEqualTo(48.dp)
    }

    @Test fun emptyDraftUsesTheNativeDisabledSendButton() {
        composer()
        ui.onNodeWithTag("button.send").assertIsNotEnabled().assertWidthIsEqualTo(40.dp)
            .assertTouchHeightIsEqualTo(48.dp).assertTouchWidthIsEqualTo(48.dp)
    }

    @Test fun longMultilineDraftScrollsInsideABoundedInput() {
        composer()
        val draft = (1..12).joinToString("\n") { "第${it}行 📝" }
        ui.onNodeWithTag("field.composer").performTextInput(draft)
        ui.onNodeWithTag("field.composer").assertTextEquals(draft)
        val bounds = ui.onNodeWithTag("field.composer").getUnclippedBoundsInRoot()
        val height = bounds.bottom - bounds.top
        assertTrue("Long drafts scroll within five visible lines: $height", height <= 168.dp)
    }

    @Test fun emptyControlSpaceDoesNotExposeAnInvisibleButton() {
        composer()
        ui.onNodeWithTag("spacer.composer.controls").assertHasNoClickAction()
    }

    @Test fun collapsedCameraUsesTheNativeIconContainerAndTouchTarget() {
        composer(expanded = false)
        val camera = ui.onNodeWithTag("button.composer.camera")
        camera.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertTouchHeightIsEqualTo(48.dp).assertTouchWidthIsEqualTo(48.dp)
        val pixels = camera.captureToImage().toPixelMap()
        var tonalPixels = 0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            if (pixels[x, y] == secondaryContainer) tonalPixels++
        }
        assertTrue("Camera uses the host Material tonal container", tonalPixels > pixels.width * pixels.height / 4)
    }

    @Test fun collapsedCaptureFillsTheSpaceBesideTheCamera() {
        composer(expanded = false)
        val surface = ui.onNodeWithTag("surface.composer.root").getUnclippedBoundsInRoot()
        val capture = ui.onNodeWithTag("button.composer.expand").getUnclippedBoundsInRoot()
        assertTrue("Capture reaches the trailing edge of its surface", surface.right - capture.right <= 8.dp)
    }

    @Test fun collapsedCaptureBlankSpaceOpensTheComposer() {
        composer(expanded = false)
        ui.onNodeWithTag("surface.composer.root").performTouchInput { click(Offset(width * .75f, height / 2f)) }
        ui.onNodeWithTag("field.composer").assertIsDisplayed()
    }

    @Test fun collapsedCaptureHasAnOpaqueMaterialSurface() {
        composer(expanded = false)
        val pixels = ui.onNodeWithTag("surface.composer.root").captureToImage().toPixelMap()
        assertTrue("The capture surface uses its Material container instead of the red journal underneath",
            pixels[(pixels.width * .75f).toInt(), pixels.height / 2] == surfaceContainerLow)
    }

    @Test fun unicodeMultilineDraftAndStatusSurviveCollapseAndReopen() {
        composer()
        val draft = "中文 📝\nSecond line\n"
        ui.onNodeWithTag("field.composer").performTextInput(draft)
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Todo").performClick()
        ui.onNodeWithTag("surface.composer.dismiss").performClick()
        ui.onNodeWithTag("button.composer.expand").performClick()
        ui.onNodeWithTag("field.composer").assertTextEquals(draft)
        ui.onNodeWithTag("button.task-status").performClick()
        ui.onNodeWithText("Clear task status").assertExists()
    }
}
