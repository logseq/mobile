package com.logseq.logseq

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.logseq.ui.AccountProfileSheet
import com.logseq.logseq.ui.compressProfilePhoto
import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AccountProfileTest {
    @get:Rule val ui = createComposeRule()

    @Test fun savesEditedNameWithoutReplacingThePhoto() {
        var savedName: String? = null
        ui.setContent {
            AccountProfileSheet(
                readProfile = { AccountProfile("Ada Chen", null) },
                updateProfile = { name, photo ->
                    assertEquals(null, photo)
                    savedName = name
                },
                dismiss = {},
            )
        }
        val recording = InstrumentationRegistry.getArguments().getString("recordAccountProfile") == "true"
        ui.waitUntil(5_000) { ui.onAllNodesWithTag("field.account.full-name").fetchSemanticsNodes().isNotEmpty() }
        if (recording) Thread.sleep(1700)
        ui.onNodeWithTag("field.account.full-name").performTextReplacement("Ada Lin")
        if (recording) Thread.sleep(1700)
        ui.onNodeWithText("Save").performClick()
        ui.runOnIdle { assertEquals("Ada Lin", savedName) }
    }

    @Test fun capsAHighlyDetailedPhotoAndKeepsTheLongestEdgeAt512Pixels() {
        val random = Random(7)
        val width = 1024
        val height = 768
        val pixels = IntArray(width * height) { random.nextInt() or 0xff000000.toInt() }
        val photo = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        val bytes = compressProfilePhoto(photo)
        assertTrue(bytes.size in 1..(128 * 1024))
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        assertEquals(512, decoded.width)
        assertEquals(384, decoded.height)
    }
}
