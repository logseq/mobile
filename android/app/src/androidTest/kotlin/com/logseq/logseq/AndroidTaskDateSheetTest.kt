package com.logseq.logseq

import android.icu.text.DateFormat
import android.icu.text.DisplayContext
import android.icu.util.TimeZone
import android.icu.util.ULocale
import androidx.activity.ComponentActivity
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalProvidableLocaleList
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import com.logseq.logseq.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import dev.lui.LuiEvent
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Date
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

        ui.setContent {
            CompositionLocalProvider(LocalProvidableLocaleList provides LocaleList(Locale("fa-IR-u-ca-persian"))) {
                MaterialExpressiveTheme { backend.Content(1) }
            }
        }
        val targetDate = Date.from(savedDay.withDayOfMonth(15).atStartOfDay(ZoneOffset.UTC).toInstant())
        val dayLabel = DateFormat.getInstanceForSkeleton(
            DatePickerDefaults.YearMonthWeekdayDaySkeleton, ULocale("fa_IR@calendar=gregorian"),
        ).apply {
            timeZone = TimeZone.GMT_ZONE
            setContext(DisplayContext.CAPITALIZATION_FOR_STANDALONE)
        }.format(targetDate)
        ui.onNode(hasText(dayLabel, substring = true) and hasClickAction()).performClick()
        ui.runOnIdle {
            val choose = events.filterIsInstance<LuiEvent.Extension>().single()
            assertEquals("choose", choose.name)
            assertEquals("20301015", choose.values["value"])
        }
    }
}
