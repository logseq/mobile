package com.logseq.app

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Canvas
import android.graphics.Paint
import android.provider.MediaStore
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.pinch
import androidx.compose.ui.test.swipeRight
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.ui.ImageGallery
import com.logseq.app.ui.saveGalleryImage
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AndroidImageGalleryTest {
    @get:Rule val ui = createComposeRule()
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val files = mutableListOf<File>()

    private fun image(color: Int): String {
        val file = File(context.cacheDir, "gallery-${UUID.randomUUID()}.png")
        val bitmap = Bitmap.createBitmap(240, 240, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(color)
        Canvas(bitmap).drawRect(80f, 80f, 160f, 160f, Paint().apply { this.color = Color.WHITE })
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        files.add(file)
        return file.path
    }

    @After fun cleanup() { files.forEach(File::delete) }

    @Test fun swipingChangesTheCurrentImageForSaveAndShare() {
        val first = image(Color.RED)
        val second = image(Color.BLUE)
        val saved = mutableListOf<String>()
        val shared = mutableListOf<String>()
        ui.setContent {
            MaterialExpressiveTheme {
                ImageGallery(listOf(first, second), 1, {}, { saved.add(it) }, { shared.add(it) })
            }
        }
        ui.onNodeWithText("2 / 2").assertIsDisplayed()
        ui.onNodeWithTag("image.preview.share").performClick()
        ui.runOnIdle { assertEquals(listOf(second), shared) }
        ui.onNodeWithTag("image.preview.gallery").performTouchInput { swipeRight() }
        ui.onNodeWithText("1 / 2").assertIsDisplayed()
        ui.onNodeWithTag("image.preview.save").performClick()
        ui.runOnIdle { assertEquals(listOf(first), saved) }
    }

    @Test fun pinchZoomKeepsTheSelectedPageAndCanBeDismissed() {
        var dismissed = false
        val first = image(Color.RED)
        val second = image(Color.BLUE)
        ui.setContent {
            MaterialExpressiveTheme { ImageGallery(listOf(first, second), 0, { dismissed = true }, {}, {}) }
        }
        val zoom = ui.onNodeWithTag("image.preview.zoom.0")
        ui.waitUntil(5_000) {
            ui.onAllNodesWithContentDescription(File(first).name).fetchSemanticsNodes().isNotEmpty()
        }
        val pixelsBefore = zoom.captureToImage().asAndroidBitmap()
        val before = zoom.fetchSemanticsNode().config[SemanticsProperties.StateDescription]
        zoom.performTouchInput {
            pinch(start0 = center - Offset(30f, 0f), end0 = center - Offset(180f, 0f),
                start1 = center + Offset(30f, 0f), end1 = center + Offset(180f, 0f))
        }
        assertNotEquals(before, zoom.fetchSemanticsNode().config[SemanticsProperties.StateDescription])
        val pixelsAfter = zoom.captureToImage().asAndroidBitmap()
        var changed = 0
        for (y in 0 until pixelsBefore.height step 8) for (x in 0 until pixelsBefore.width step 8) {
            if (pixelsBefore.getPixel(x, y) != pixelsAfter.getPixel(x, y)) changed++
        }
        assertTrue("Pinching changes the drawn image, not only its accessibility state", changed > 100)
        ui.onNodeWithTag("image.preview.gallery").performTouchInput { swipeRight() }
        ui.onNodeWithText("1 / 2").assertIsDisplayed()
        ui.onNodeWithTag("image.preview.close").performClick()
        ui.runOnIdle { assertTrue(dismissed) }
    }

    @Test fun anUnavailableImageRemainsDismissibleWithoutSaveOrShare() {
        var dismissed = false
        ui.setContent {
            MaterialExpressiveTheme {
                ImageGallery(listOf("/missing/gallery-image.png"), 20, { dismissed = true }, {}, {})
            }
        }
        ui.onNodeWithText("Image unavailable").assertIsDisplayed()
        ui.onNodeWithTag("image.preview.save").assertIsNotEnabled()
        ui.onNodeWithTag("image.preview.share").assertIsNotEnabled()
        ui.onNodeWithTag("image.preview.close").performClick()
        ui.runOnIdle { assertTrue(dismissed) }
    }

    @Test fun saveCopiesTheOriginalImageToTheSystemPhotoLibrary() {
        val path = image(Color.GREEN)
        val uri = saveGalleryImage(context, path)
        try {
            val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            assertArrayEquals(File(path).readBytes(), bytes)
            context.contentResolver.query(uri, arrayOf(MediaStore.Images.Media.MIME_TYPE), null, null, null)!!.use {
                assertTrue(it.moveToFirst())
                assertEquals("image/png", it.getString(0))
            }
        } finally { context.contentResolver.delete(uri, null, null) }
    }
}
