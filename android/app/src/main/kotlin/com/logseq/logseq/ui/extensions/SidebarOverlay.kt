package com.logseq.logseq.ui.extensions

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.gestures.scrollable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.core.view.HapticFeedbackConstantsCompat
import androidx.core.view.ViewCompat
import dev.lui.LocalLuiScrollingEnabled
import dev.lui.LocalLuiThemeDark
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sqrt

internal val LocalSidebarBlocksMain = compositionLocalOf { false }
private val LocalSidebarScroll = compositionLocalOf<ScrollState?> { null }

internal fun LuiExtensionRegistry.registerSidebarOverlay() {
    register(
        "sidebar-overlay",
        "lui-extension-v1|15:sidebar-overlay|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:" +
            "11:settings-id:int:required:none,13:dismiss-label:string:required:none,4:open:bool:required:none,5:width:int:required:none," +
            "7:enabled:bool:required:none,7:main-id:int:required:none,8:panel-id:int:required:none|events:4:open[],5:close[]",
        acceptsStandardChildren = true,
        properties = listOf(
            LuiExtensionProperty("open", LuiExtensionValueKind.BOOLEAN, required = true),
            LuiExtensionProperty("enabled", LuiExtensionValueKind.BOOLEAN, required = true),
            LuiExtensionProperty("width", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("main-id", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("panel-id", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("settings-id", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("dismiss-label", LuiExtensionValueKind.STRING, required = true),
        ),
        events = listOf(LuiExtensionEventSchema("open"), LuiExtensionEventSchema("close")),
    ) { SidebarOverlay(this) }
    register(
        "sidebar-scroll",
        "lui-extension-v1|14:sidebar-scroll|profiles:android/kotlin|standard-children:1|children:|properties:|events:",
        acceptsStandardChildren = true,
    ) {
        val scroll = LocalSidebarScroll.current ?: rememberScrollState()
        Box(Modifier.fillMaxSize().testTag("scroll.sidebar.pages").verticalScroll(scroll)) { Children() }
    }
}

@Composable
private fun SidebarOverlay(context: LuiExtensionContext) {
    val main = context.int("main-id")?.toLong() ?: return
    val panel = context.int("panel-id")?.toLong() ?: return
    val settings = context.int("settings-id")?.toLong() ?: return
    val open = context.flag("open")
    val canOpen = context.flag("enabled") && LogseqDialogs.journalCalendar == null
    val dismissLabel = context.string("dismiss-label").orEmpty()
    val scope = rememberCoroutineScope()
    val motion = remember { SidebarMotion(open, scope) }
    val sidebarScroll = rememberScrollState()
    val view = LocalView.current
    val latestOpen by rememberUpdatedState(open)
    val latestCanOpen by rememberUpdatedState(canOpen)
    val latestContext by rememberUpdatedState(context)
    val select: (Boolean, Float) -> Unit = { value, velocity ->
        val next = value && (latestCanOpen || latestOpen)
        if (next != latestOpen) latestContext.emit(if (next) "open" else "close")
        motion.settle(next, velocity)
    }
    val latestSelect by rememberUpdatedState(select)
    LaunchedEffect(open) {
        motion.settle(open)
        if (motion.lastOpen != open) {
            ViewCompat.performHapticFeedback(view, HapticFeedbackConstantsCompat.CONFIRM)
            motion.lastOpen = open
        }
    }

    val colors = MaterialTheme.colorScheme
    val dark = LocalLuiThemeDark.current ?: androidx.compose.foundation.isSystemInDarkTheme()
    val supportsBlur = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    val blocksMain by remember(open) { derivedStateOf { open || motion.progress > 0.001f } }
    // Change the input tree with the target state so it stays stable during the spring.
    val panelInteractive = open
    BackHandler(enabled = blocksMain) { select(false, 0f) }

    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds().testTag("application.shell")) {
        val width = minOf((context.int("width") ?: 320).dp, maxWidth * 0.80f)
        val density = LocalDensity.current
        val widthPx = with(density) { width.toPx() }.coerceAtLeast(1f)
        val blurPx = with(density) { 26.dp.toPx() }
        val panelBlurPx = with(density) { 12.dp.toPx() }
        val viewportWidthPx = with(density) { maxWidth.toPx() }
        val direction = if (LocalLayoutDirection.current == LayoutDirection.Ltr) 1f else -1f
        val glassTint = remember(colors, dark, viewportWidthPx, direction) {
            Brush.horizontalGradient(
                0f to (if (dark) colors.surfaceContainer else colors.background).copy(alpha = if (dark) 0.68f else 0.78f),
                0.65f to colors.background.copy(alpha = if (dark) 0.58f else 0.68f),
                1f to colors.background.copy(alpha = if (dark) 0.36f else 0.47f),
                startX = if (direction > 0f) 0f else viewportWidthPx,
                endX = if (direction > 0f) viewportWidthPx else 0f,
            )
        }
        Box(
            Modifier.fillMaxSize()
                .sidebarPan(
                    motion, widthPx, direction,
                    { latestCanOpen }, { latestOpen }, { value, velocity -> latestSelect(value, velocity) },
                )
                // Drags on the backdrop and Settings use the same viewport as drags on the panel.
                .scrollable(sidebarScroll, Orientation.Vertical, enabled = open, reverseDirection = true),
        ) {
            CompositionLocalProvider(
                LocalLuiScrollingEnabled provides !blocksMain,
                LocalSidebarBlocksMain provides blocksMain,
            ) {
                Box(
                    Modifier.fillMaxSize().graphicsLayer {
                        val radius = blurPx * motion.progress
                        renderEffect = if (supportsBlur && radius > 0f) BlurEffect(radius, radius, TileMode.Clamp) else null
                    }.then(if (blocksMain) Modifier.semantics { hideFromAccessibility() } else Modifier),
                ) { context.child(main) }
            }
            Canvas(Modifier.matchParentSize()) {
                val progress = motion.progress
                if (progress > 0f) {
                    if (supportsBlur) drawRect(brush = glassTint, alpha = progress)
                    else drawRect(color = colors.background, alpha = progress)
                }
            }
            if (blocksMain) {
                // Keep the drawer's leading region modal even while the panel animates.
                SidebarHitShield(Modifier.fillMaxHeight().width(width))
                Box(Modifier.matchParentSize().padding(start = width)
                    // Cancel a pending click even when a horizontal drag stays within the backdrop.
                    .draggable(rememberDraggableState {}, Orientation.Horizontal)
                    .clickable(interactionSource = null, indication = null, role = Role.Button) { select(false, 0f) }
                    .testTag("button.sidebar.dismiss").semantics {
                        contentDescription = dismissLabel
                        if (!open) hideFromAccessibility()
                    })
            }
            if (motion.hasOpened) {
                Box(Modifier.matchParentSize().graphicsLayer {
                    val progress = motion.progress
                    alpha = progress
                    translationX = direction * (if (blocksMain) (progress - 1f) * widthPx else -viewportWidthPx)
                    val radius = panelBlurPx * sqrt(1f - progress)
                    renderEffect = if (supportsBlur && progress > 0f && radius > 0f) {
                        BlurEffect(radius, radius, TileMode.Decal)
                    } else null
                }.then(if (!panelInteractive) Modifier.semantics { hideFromAccessibility() } else Modifier)) {
                    // Content stays mounted across transitions, as on iOS.
                    MaterialTheme(colorScheme = colors.copy(
                        surface = Color.Transparent,
                        secondaryContainer = Color.Transparent,
                        onSecondaryContainer = colors.onSurface,
                    )) {
                        Box(Modifier.width(width).fillMaxHeight()) {
                            CompositionLocalProvider(LocalSidebarScroll provides sidebarScroll) {
                                context.child(panel)
                            }
                            if (!panelInteractive) SidebarHitShield(Modifier.matchParentSize())
                        }
                    }
                    Box(Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 16.dp)) {
                        context.child(settings)
                        if (!panelInteractive) SidebarHitShield(Modifier.matchParentSize())
                    }
                }
            }
        }
    }
}

@Composable
private fun SidebarHitShield(modifier: Modifier) {
    // Win sibling hit testing without claiming the parent pan's pointer events.
    Box(modifier.pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent() } })
}

// SwiftUI Spring(duration: 0.30, bounce: 0), with a unit mass.
private const val SIDEBAR_SPRING_STIFFNESS = 438.65f
private val sidebarSpring = spring<Float>(
    dampingRatio = Spring.DampingRatioNoBouncy,
    stiffness = SIDEBAR_SPRING_STIFFNESS,
)

private class SidebarMotion(open: Boolean, private val scope: CoroutineScope) {
    var progress by mutableFloatStateOf(if (open) 1f else 0f)
        private set
    var hasOpened by mutableStateOf(open)
        private set
    var lastOpen = open
    private var target: Float? = progress
    private var animation: Job? = null

    fun beginDrag(): Float {
        animation?.cancel()
        target = null
        hasOpened = true
        return progress
    }

    fun drag(start: Float, fraction: Float) {
        progress = if (fraction > 0f) {
            // Use the iPhone's quicker reveal only while following a rightward pan.
            1f - (1f - start) * (1f - fraction).coerceAtLeast(0f).pow(5)
        } else {
            (start + fraction).coerceAtLeast(0f)
        }
    }

    fun settle(open: Boolean, velocity: Float = 0f) {
        val destination = if (open) 1f else 0f
        if (target == destination) return
        animation?.cancel()
        target = destination
        if (open) hasOpened = true
        val remaining = destination - progress
        if (remaining == 0f) return
        // Stay within the velocity that reaches the target monotonically at critical damping.
        val velocityLimit = remaining * sqrt(SIDEBAR_SPRING_STIFFNESS)
        val initialVelocity = velocity.coerceIn(minOf(0f, velocityLimit), maxOf(0f, velocityLimit))
        animation = scope.launch {
            animate(
                initialValue = progress,
                targetValue = destination,
                initialVelocity = initialVelocity,
                animationSpec = sidebarSpring,
            ) { value, _ -> progress = value.coerceIn(0f, 1f) }
        }
    }
}

private const val SIDEBAR_SETTLE_POINT = 0.5f

internal fun sidebarSettlesOpen(position: Float, velocity: Float, revealed: Float, opening: Boolean): Boolean {
    // A small reversal at lift-off can't reopen a panel dragged past its closing threshold.
    val projectedVelocity = if (opening) velocity else minOf(velocity, 0f)
    // A sparse touch stream can drop the fling estimate even after the panel visibly opened.
    return position + projectedVelocity * 0.16f >= SIDEBAR_SETTLE_POINT ||
        (opening && revealed >= 0.75f && velocity >= -0.5f)
}

private fun Modifier.sidebarPan(
    motion: SidebarMotion,
    width: Float,
    direction: Float,
    canOpen: () -> Boolean,
    isOpen: () -> Boolean,
    select: (Boolean, Float) -> Unit,
): Modifier = pointerInput(motion, width, direction) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val startsOpen = isOpen()
        if (!startsOpen && !canOpen()) return@awaitEachGesture
        // Give a closing swipe priority over the backdrop's click cancellation.
        // When closed, let page scrollers and pagers handle their own gestures first.
        val pass = if (startsOpen) PointerEventPass.Initial else PointerEventPass.Main
        val velocity = VelocityTracker()
        velocity.addPosition(down.uptimeMillis, down.position)
        var start: Float? = null
        var lastMoveTime = down.uptimeMillis
        var leastRevealed = 1f
        val reversalSlop = viewConfiguration.touchSlop / width
        fun releasePosition(position: Float): Float {
            if (!startsOpen || position - leastRevealed > reversalSlop) return position
            return minOf(position, leastRevealed)
        }
        try {
            while (true) {
                val event = awaitPointerEvent(pass)
                if (event.changes.count { it.pressed } > 1) break
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (change.isConsumed || isOpen() != startsOpen) break
                val travel = change.position - down.position
                val horizontal = travel.x * direction
                val fraction = horizontal / width
                if (!change.pressed) {
                    start?.let { initial ->
                        change.consume()
                        motion.drag(initial, fraction)
                        val speed = if (change.uptimeMillis - lastMoveTime < 80) {
                            velocity.calculateVelocity().x * direction / width
                        } else 0f
                        start = null
                        val settleOpen = sidebarSettlesOpen(
                            releasePosition(initial + fraction), speed, motion.progress, opening = !startsOpen,
                        )
                        select(settleOpen, speed)
                    }
                    break
                }
                velocity.addPosition(change.uptimeMillis, change.position)
                lastMoveTime = change.uptimeMillis
                if (start == null) {
                    if (travel.getDistance() < viewConfiguration.touchSlop) continue
                    if (abs(horizontal) <= 2f * abs(travel.y)) break
                    val canDrag = if (startsOpen) {
                        horizontal < 0f && motion.progress > 0.01f
                    } else {
                        horizontal > 0f && canOpen() && motion.progress < 0.99f
                    }
                    if (!canDrag) break
                    start = motion.beginDrag()
                }
                motion.drag(checkNotNull(start), fraction)
                change.consume()
                leastRevealed = minOf(leastRevealed, motion.progress)
                if (startsOpen && motion.progress == 0f) {
                    // The panel has cleared the viewport. Finish this swipe before the touch can be lost.
                    start = null
                    select(false, 0f)
                    break
                }
            }
        } finally {
            if (start != null) {
                val open = isOpen()
                if (startsOpen && open && releasePosition(motion.progress) < SIDEBAR_SETTLE_POINT) {
                    select(false, 0f)
                } else {
                    motion.settle(open)
                }
            }
        }
    }
}
