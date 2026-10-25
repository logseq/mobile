package com.logseq.app.ui.extensions

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.TimeInput
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Constraints
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
import kotlinx.coroutines.flow.distinctUntilChanged

internal val LocalPropertyValue = staticCompositionLocalOf { false }

internal fun LuiExtensionRegistry.registerProperties() {
    register("native-table-viewport",
        "lui-extension-v1|21:native-table-viewport|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:identifier:string:required:none|events:16:viewport-changed[5:width:int:required,6:offset:int:required]",
        acceptsStandardChildren = true,
        properties = listOf(LuiExtensionProperty("identifier", LuiExtensionValueKind.STRING, required = true)),
        events = listOf(LuiExtensionEventSchema("viewport-changed", listOf(
            LuiExtensionProperty("offset", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("width", LuiExtensionValueKind.INTEGER, required = true)))),
    ) { TableViewport(this) }
    register("native-property-row",
        "lui-extension-v1|19:native-property-row|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:7:stacked:bool:required:none|events:",
        acceptsStandardChildren = true,
        properties = listOf(LuiExtensionProperty("stacked", LuiExtensionValueKind.BOOLEAN, required = true)),
    ) {
        CompositionLocalProvider(LocalPropertyValue provides true) { PropertyRow(this) }
    }
    register("outliner-continuation",
        "lui-extension-v1|21:outliner-continuation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:identifier:string:required:none,11:guide-count:int:required:none,12:bullet-depth:int:required:none|events:",
        acceptsStandardChildren = true,
        properties = listOf(
            LuiExtensionProperty("bullet-depth", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("guide-count", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("identifier", LuiExtensionValueKind.STRING, required = true),
        ),
    ) {
        val count = int("guide-count") ?: 0
        val bulletDepth = int("bullet-depth") ?: -1
        val color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f)
        Box(Modifier.fillMaxWidth().testTag("outliner." + (string("identifier") ?: "").replace("metadata.", "metadata.guides."))
            .drawBehind {
                for (level in 0 until count) {
                    val x = (12 + level * 22).dp.toPx()
                    val top = if (level == bulletDepth) 17.5.dp.toPx() else 0f
                    if (size.height > top) drawLine(color, Offset(x, top), Offset(x, size.height), strokeWidth = 1.dp.toPx())
                }
            }) { Children() }
    }
    register("native-property-date",
        "lui-extension-v1|20:native-property-date|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:10:identifier:string:required:none,4:kind:string:required:none,5:value:string:required:none|events:6:change[5:value:string:required]",
        properties = listOf(
            LuiExtensionProperty("identifier", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("kind", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("value", LuiExtensionValueKind.STRING, required = true),
        ),
        events = listOf(LuiExtensionEventSchema("change", listOf(LuiExtensionProperty("value", LuiExtensionValueKind.STRING, required = true)))),
    ) { PropertyDatePicker(this) }
}

@Composable
private fun PropertyRow(context: LuiExtensionContext) {
    val stacked = context.bool("stacked") == true
    Layout(content = { context.Children() }, modifier = Modifier.fillMaxWidth()) { children, constraints ->
        if (children.size != 2) return@Layout layout(0, 0) {}
        val width = constraints.maxWidth
        val intrinsic = children[0].maxIntrinsicWidth(Constraints.Infinity)
        val keyWidth = if (intrinsic <= 24.dp.roundToPx()) intrinsic else minOf(144.dp.roundToPx(), (width * 0.44f).toInt())
        val gap = 8.dp.roundToPx()
        val vertical = stacked || intrinsic > keyWidth || width - keyWidth - gap < 96.dp.roundToPx()
        val key = children[0].measure(Constraints(maxWidth = if (vertical) width else keyWidth))
        val value = children[1].measure(Constraints(maxWidth = if (vertical) width else width - keyWidth - gap))
        val rowGap = 2.dp.roundToPx()
        val height = if (vertical) key.height + rowGap + value.height else maxOf(key.height, value.height)
        layout(width, height) {
            key.placeRelative(0, if (vertical) 0 else (height - key.height) / 2)
            value.placeRelative(if (vertical) 0 else keyWidth + gap, if (vertical) key.height + rowGap else (height - value.height) / 2)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PropertyDatePicker(context: LuiExtensionContext) {
    val time = context.string("kind") == "datetime"
    val source = context.string("value") ?: ""
    val currentSource by rememberUpdatedState(source)
    val zone = ZoneId.systemDefault()
    val initial = remember {
        if (time) (source.toLongOrNull()?.let(Instant::ofEpochMilli) ?: Instant.now()).atZone(zone)
        else (runCatching { LocalDate.parse(source) }.getOrDefault(LocalDate.now())).atStartOfDay(zone)
    }
    val date = rememberDatePickerState(initialSelectedDateMillis = initial.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
    val clock = rememberTimePickerState(initialHour = initial.hour, initialMinute = initial.minute)
    LaunchedEffect(Unit) {
        snapshotFlow { Triple(date.selectedDateMillis, clock.hour, clock.minute) }.distinctUntilChanged().collect { (millis, hour, minute) ->
            if (millis != null) {
                val day = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
                val value = if (time) day.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli().toString() else day.toString()
                if (value != currentSource) context.emit("change", mapOf("value" to value))
            }
        }
    }
    Column(Modifier.fillMaxWidth().testTag(context.string("identifier") ?: "")) {
        DatePicker(state = date, showModeToggle = false)
        if (time) TimeInput(state = clock)
    }
}

@Composable
private fun TableViewport(context: LuiExtensionContext) {
    val scroll = rememberScrollState()
    val current by rememberUpdatedState(context)
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val width = maxWidth.value.toInt().coerceAtLeast(1)
        LaunchedEffect(scroll, width, density) {
            snapshotFlow { scroll.value }.distinctUntilChanged().collect { offset ->
                current.emit("viewport-changed", "offset" to (offset / density.density).toInt(), "width" to width)
            }
        }
        Column(Modifier.fillMaxWidth().horizontalScroll(scroll).testTag(context.string("identifier") ?: "")) {
            context.Children()
        }
    }
}
