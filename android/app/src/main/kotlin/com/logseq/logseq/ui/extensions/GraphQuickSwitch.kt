package com.logseq.logseq.ui.extensions

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import kotlin.math.abs

internal fun LuiExtensionRegistry.registerGraphQuickSwitch() {
    register(
        "graph-quick-switch",
        "lui-extension-v1|18:graph-quick-switch|profiles:android/kotlin,ios/swiftui|standard-children:1|children:" +
            "|properties:11:target-name:string:required:none,12:action-label:string:required:none,9:target-id:string:required:none" +
            "|events:6:switch[5:value:string:required]",
        acceptsStandardChildren = true,
        properties = listOf(
            LuiExtensionProperty("target-id", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("target-name", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("action-label", LuiExtensionValueKind.STRING, required = true),
        ),
        events = listOf(LuiExtensionEventSchema(
            "switch", listOf(LuiExtensionProperty("value", LuiExtensionValueKind.STRING, required = true)),
        )),
    ) { GraphQuickSwitch(this) }
}

@Composable
private fun GraphQuickSwitch(context: LuiExtensionContext) {
    val target = context.string("target-id").orEmpty()
    val name = context.string("target-name").orEmpty()
    val actionLabel = context.string("action-label").orEmpty()
    fun switchGraph() { context.emit("switch", "value" to target) }

    var distance by remember(target) { mutableFloatStateOf(0f) }
    val swipe = if (target.isEmpty()) Modifier else Modifier.pointerInput(target) {
        val minimumFlickDistance = 30.dp.toPx()
        val minimumFlickVelocity = 650.dp.toPx()
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val velocity = VelocityTracker()
            velocity.addPosition(down.uptimeMillis, down.position)
            var dragging = false
            try {
                while (true) {
                    val event = awaitPointerEvent()
                    if (event.changes.size != 1) break
                    val change = event.changes.single()
                    if (change.id != down.id) break
                    val delta = change.position - down.position
                    velocity.addPosition(change.uptimeMillis, change.position)

                    if (!change.pressed) {
                        if (dragging && (-delta.x > size.width * 0.3f ||
                                (-delta.x > minimumFlickDistance &&
                                    -velocity.calculateVelocity().x > minimumFlickVelocity))) {
                            switchGraph()
                        }
                        break
                    }
                    if (change.isConsumed) break
                    if (!dragging && maxOf(abs(delta.x), abs(delta.y)) > viewConfiguration.touchSlop) {
                        // Leave rightward gestures to the drawer and vertical gestures to the list.
                        if (-delta.x <= abs(delta.y) * 1.4f) break
                        dragging = true
                    }
                    if (dragging) {
                        change.consume()
                        distance = (-delta.x).coerceAtLeast(0f)
                    }
                }
            } finally {
                distance = 0f
            }
        }
    }
    val accessibility = if (target.isEmpty() || actionLabel.isEmpty()) Modifier else Modifier.semantics {
        customActions = listOf(CustomAccessibilityAction(actionLabel) {
            switchGraph()
            true
        })
    }
    val previewTravel = with(LocalDensity.current) { 48.dp.toPx() }
    Box(Modifier.fillMaxSize().then(swipe).then(accessibility)) {
        context.Children()
        if (target.isNotEmpty()) {
            Text(
                name,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 72.dp, start = 24.dp, end = 24.dp)
                    .graphicsLayer {
                        alpha = (distance / (previewTravel / 2)).coerceIn(0f, 1f)
                        translationX = (previewTravel - distance).coerceAtLeast(0f)
                    }
                    // A visual background keeps the preview out of pointer hit testing.
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape)
                    .padding(horizontal = 14.dp, vertical = 8.dp)
                    .clearAndSetSemantics {},
                color = MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
