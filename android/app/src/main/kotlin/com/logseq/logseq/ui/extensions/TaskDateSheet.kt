package com.logseq.logseq.ui.extensions

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import org.json.JSONObject

internal fun LuiExtensionRegistry.registerTaskDateSheet() {
    val value = LuiExtensionProperty("value", LuiExtensionValueKind.STRING, required = true)
    register(
        "native-task-date-sheet",
        "lui-extension-v1|22:native-task-date-sheet|profiles:android/kotlin,ios/swiftui|" +
            "standard-children:0|children:|properties:7:payload:string:required:none|" +
            "events:5:clear[],6:choose[5:value:string:required],6:submit[5:value:string:required],7:dismiss[]",
        properties = listOf(LuiExtensionProperty("payload", LuiExtensionValueKind.STRING, required = true)),
        events = listOf(
            LuiExtensionEventSchema("clear", emptyList()),
            LuiExtensionEventSchema("choose", listOf(value)),
            LuiExtensionEventSchema("submit", listOf(value)),
            LuiExtensionEventSchema("dismiss", emptyList()),
        ),
    ) {
        val payload = string("payload")
        val state = remember(payload) { payload?.let { runCatching { JSONObject(it) }.getOrNull() } }
        if (state != null) TaskDateSheet(this, state)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskDateSheet(context: LuiExtensionContext, state: JSONObject) {
    ModalBottomSheet(
        onDismissRequest = { context.emit("dismiss") },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        val focus = LocalFocusManager.current
        val ready = state.optBoolean("ready")
        val waiting = state.optBoolean("waiting")
        val enabled = ready && !waiting
        val error = if (state.isNull("error")) null else state.optString("error")
        var input by remember { mutableStateOf("") }
        val canSubmit = enabled && input.isNotBlank()
        val submit = { if (canSubmit) context.emit("submit", mapOf("value" to input)) }

        Column(Modifier.fillMaxWidth().testTag("sheet.task-dates")
            .semantics { testTagsAsResourceId = true }) {
            TextField(
                value = input,
                onValueChange = { input = it },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("task-dates.input"),
                placeholder = { Text(state.optString("title")) },
                enabled = enabled,
                singleLine = true,
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = if (input.isEmpty()) null else {
                    {
                        IconButton(onClick = submit, enabled = canSubmit, modifier = Modifier.testTag("task-dates.submit")) {
                            Icon(Icons.Filled.Check, contentDescription = state.optString("submitTitle"))
                        }
                    }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
            HorizontalDivider(Modifier.padding(top = 8.dp))
            if (ready) {
                val selection = if (state.isNull("value")) null else {
                    Instant.ofEpochMilli(state.getLong("value")).atZone(ZoneId.systemDefault()).toLocalDate()
                }
                Box(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
                    TaskDateCalendar(selection, enabled) { day ->
                        focus.clearFocus()
                        context.emit("choose", mapOf("value" to (day.year * 10_000 + day.monthValue * 100 + day.dayOfMonth).toString()))
                    }
                }
            } else {
                Box(Modifier.fillMaxWidth().height(240.dp).weight(1f, fill = false),
                    contentAlignment = Alignment.Center) {
                    if (waiting) CircularProgressIndicator(Modifier.testTag("task-dates.loading"))
                }
            }
            if (error != null) {
                Text(error, Modifier.padding(horizontal = 16.dp).testTag("task-dates.error"),
                    color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            } else if (state.optBoolean("mixed")) {
                Text(state.optString("mixedTitle"), Modifier.padding(horizontal = 16.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
            TextButton(
                onClick = {
                    focus.clearFocus()
                    context.emit("clear")
                },
                enabled = enabled && state.optBoolean("canClear"),
                modifier = Modifier.padding(horizontal = 12.dp).testTag("task-dates.clear"),
            ) { Text(state.optString("clearTitle")) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskDateCalendar(selection: LocalDate?, enabled: Boolean, onChoose: (LocalDate) -> Unit) {
    val yearRange = 1..9999
    val selectedMillis = selection?.takeIf { it.year in yearRange }?.let { it.toEpochDay() * 86_400_000L }
    val calendar = rememberDatePickerState(
        initialSelectedDateMillis = selectedMillis,
        initialDisplayedMonthMillis = selectedMillis ?: LocalDate.now().toEpochDay() * 86_400_000L,
        yearRange = yearRange,
    )
    LaunchedEffect(selectedMillis) { calendar.selectedDateMillis = selectedMillis }
    val choose by rememberUpdatedState(onChoose)
    val picker = remember(calendar, enabled) {
        object : DatePickerState by calendar {
            override val selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long) = enabled
                override fun isSelectableYear(year: Int) = enabled
            }

            override var selectedDateMillis: Long?
                get() = calendar.selectedDateMillis
                set(value) {
                    if (enabled && value != null) choose(Instant.ofEpochMilli(value).atZone(ZoneOffset.UTC).toLocalDate())
                }
        }
    }
    DatePicker(state = picker, modifier = Modifier.testTag("task-dates.calendar"),
        title = null, headline = null, showModeToggle = false)
}
