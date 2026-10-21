package com.logseq.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.espresso.Espresso
import com.logseq.app.runtime.AndroidGraphProgress
import com.logseq.app.ui.GraphProgressDialog
import org.junit.Rule
import org.junit.Test

class AndroidGraphProgressTest {
    @get:Rule val ui = createComposeRule()

    @Test fun realRecordCountsUpdateAndBackCannotDismissAnActiveImport() {
        val progress = mutableStateOf<AndroidGraphProgress?>(AndroidGraphProgress("g", "My graph", "downloading"))
        ui.setContent { MaterialTheme { GraphProgressDialog(progress.value) } }
        ui.onNodeWithText("My graph").assertIsDisplayed()
        ui.onNodeWithText("Getting your notes…").assertIsDisplayed()
        ui.runOnIdle { progress.value = AndroidGraphProgress("g", "My graph", "importing", 1234, 5000) }
        ui.onNodeWithText("1234 / 5000 records").assertIsDisplayed()
        Espresso.pressBack()
        ui.onNodeWithText("1234 / 5000 records").assertIsDisplayed()
        ui.runOnIdle { progress.value = null }
        ui.onNodeWithText("My graph").assertDoesNotExist()
    }
}
