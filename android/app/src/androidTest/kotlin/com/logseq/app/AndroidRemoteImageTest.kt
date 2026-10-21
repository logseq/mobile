package com.logseq.app

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.ui.extensions.GraphImagePreview
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class AndroidRemoteImageTest {
    @get:Rule val ui = createComposeRule()

    @Test fun failedImageRetriesAndOpensTheDownloadedFile() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val image = File.createTempFile("remote-image", ".png", context.cacheDir)
        val bitmap = Bitmap.createBitmap(30, 30, Bitmap.Config.ARGB_8888)
        image.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        var attempts = 0
        var opened = ""
        try {
            ui.setContent { MaterialTheme {
                GraphImagePreview("uuid", "Remote image", "png", "", { _, _ ->
                    attempts++
                    if (attempts == 1) error("Offline")
                    image.path
                }, { opened = it })
            } }
            ui.onNodeWithText("Retry").assertIsDisplayed().performClick()
            ui.waitUntil(5_000) { ui.onAllNodesWithTag("asset.preview.image").fetchSemanticsNodes().isNotEmpty() }
            ui.onNodeWithTag("asset.preview.image").performClick()
            ui.runOnIdle { assertEquals(2, attempts); assertEquals(image.path, opened) }
        } finally { image.delete() }
    }
}
