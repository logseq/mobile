package com.logseq.logseq

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.lui.LuiBackend
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidLuiLayoutTest {
    @get:Rule val ui = createComposeRule()

    @Test fun stretchRowCanMeasureAColumnWithNaturalHeight() {
        val backend = LuiBackend()
        assertTrue(backend.applyJson("""
            {"generation":1,"ops":[
                {"op":"create-node","id":1,"kind":"row"},
                {"op":"set-prop","id":1,"property":"cross","value":"stretch"},
                {"op":"create-node","id":2,"kind":"column"},
                {"op":"set-prop","id":2,"property":"width","value":220},
                {"op":"create-node","id":3,"kind":"text"},
                {"op":"set-prop","id":3,"property":"text","value":"Column inside stretch row"},
                {"op":"insert-child","parent":1,"child":2,"index":0},
                {"op":"insert-child","parent":2,"child":3,"index":0}
            ]}
        """.trimIndent()))
        ui.setContent { MaterialTheme { backend.Content(1) } }
        ui.onNodeWithText("Column inside stretch row").assertIsDisplayed()
    }
}
