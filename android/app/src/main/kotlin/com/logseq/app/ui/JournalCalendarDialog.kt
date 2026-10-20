package com.logseq.app.ui

import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import com.logseq.app.ui.extensions.LogseqDialogs
import java.time.LocalDate

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun JournalCalendarDialog() {
    val request = LogseqDialogs.journalCalendar ?: return
    val today = remember(request) { LocalDate.now() }
    val initial = remember(today) { today.toEpochDay() * 86_400_000L }
    val state = rememberDatePickerState(initialSelectedDateMillis = initial)
    fun select(date: LocalDate) {
        request.complete(date.year * 10_000 + date.monthValue * 100 + date.dayOfMonth)
    }
    LaunchedEffect(state.selectedDateMillis) {
        state.selectedDateMillis?.takeIf { it != initial }?.let {
            select(LocalDate.ofEpochDay(it / 86_400_000L))
        }
    }
    DatePickerDialog(
        modifier = Modifier.semantics { testTagsAsResourceId = true }.testTag("dialog.journal-calendar"),
        onDismissRequest = { request.complete(null) },
        confirmButton = {
            TextButton(onClick = { select(today) }, modifier = Modifier.testTag("button.journal-calendar.today")) {
                Text("Today")
            }
        },
        dismissButton = {
            TextButton(onClick = { request.complete(null) }) { Text("Cancel") }
        },
    ) {
        DatePicker(
            state = state,
            title = {
                Text("Go to journal", style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 16.dp))
            },
            showModeToggle = false,
            modifier = Modifier.testTag("picker.journal-date"),
        )
    }
}
