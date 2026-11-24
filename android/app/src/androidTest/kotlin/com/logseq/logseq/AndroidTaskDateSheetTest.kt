package com.logseq.logseq

import android.content.res.Configuration
import android.os.LocaleList
import android.view.ContextThemeWrapper
import androidx.activity.ComponentActivity
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AndroidTaskDateSheetTest {
    @get:Rule val ui = createAndroidComposeRule<ComponentActivity>()

    @OptIn(ExperimentalMaterial3Api::class)
    @Test fun tappingCalendarDayImmediatelyChoosesIt() {
        val identifier = "native-task-date-sheet"
        val registry = logseqExtensionRegistry()
        val events = mutableListOf<LuiEvent>()
        val backend = LuiBackend(onEvent = { events.add(it) }, extensions = registry)
        val savedDay = LocalDate.of(2030, 10, 12)
        val payload = JSONObject().put("title", "Scheduled").put("clearTitle", "Clear Scheduled")
            .put("submitTitle", "Save").put("mixedTitle", "Mixed dates")
            .put("value", savedDay.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli())
            .put("ready", true).put("waiting", false).put("canClear", true).put("mixed", false)
            .put("error", JSONObject.NULL)
        val ops = JSONArray().put(JSONObject().put("op", "create-node").put("id", 1).put("kind", "root"))
            .put(JSONObject().put("op", "create-extension").put("id", 2).put("identifier", identifier)
                .put("fingerprint", registry.registration(identifier)!!.fingerprint))
            .put(JSONObject().put("op", "insert-child").put("parent", 1).put("child", 2).put("index", 0))
            .put(JSONObject().put("op", "set-extension-prop").put("id", 2)
                .put("property", "payload").put("value", payload.toString()))
        assertTrue(backend.lastError, backend.applyJson(JSONObject().put("generation", 1).put("ops", ops).toString()))

        val persianLocale = Locale.forLanguageTag("fa-IR-u-ca-persian")
        val activity = ui.activity
        ui.runOnUiThread {
            // The bottom sheet creates a new Compose root from the host view's context.
            val context = ContextThemeWrapper(activity, 0).apply {
                applyOverrideConfiguration(Configuration().apply { setLocales(LocaleList(persianLocale)) })
            }
            activity.setContentView(ComposeView(context).apply {
                setContent { MaterialExpressiveTheme { backend.Content(1) } }
            })
        }
        val targetDate = savedDay.withDayOfMonth(15).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        val gregorianLocale = Locale.Builder().setLocale(persianLocale)
            .setUnicodeLocaleKeyword("ca", "gregory").build()
        val dayLabel = requireNotNull(DatePickerDefaults.dateFormatter().formatDate(
            targetDate, gregorianLocale, forContentDescription = true,
        ))
        ui.onNode(hasText(dayLabel, substring = true) and hasClickAction() and
            hasAnyAncestor(hasTestTag("task-dates.calendar"))).performClick()
        ui.runOnIdle {
            val choose = events.filterIsInstance<LuiEvent.Extension>().single()
            assertEquals("choose", choose.name)
            assertEquals("20301015", choose.values["value"])
        }
    }
}
