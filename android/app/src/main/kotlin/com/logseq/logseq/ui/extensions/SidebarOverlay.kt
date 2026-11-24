package com.logseq.logseq.ui.extensions

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import dev.lui.LocalLuiScrollingEnabled
import dev.lui.LocalLuiThemeDark
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import kotlinx.coroutines.flow.drop

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
}

@Composable
private fun SidebarOverlay(context: LuiExtensionContext) {
    val main = context.int("main-id")?.toLong() ?: return
    val panel = context.int("panel-id")?.toLong() ?: return
    val settings = context.int("settings-id")?.toLong() ?: return
    val open = context.flag("open")
    val enabled = context.flag("enabled")
    val latestContext by rememberUpdatedState(context)
    val modelOpen by rememberUpdatedState(open)
    val drawer = rememberDrawerState(if (open) DrawerValue.Open else DrawerValue.Closed)
    LaunchedEffect(open) {
        if (open) drawer.open() else drawer.close()
    }
    LaunchedEffect(drawer) {
        snapshotFlow { drawer.currentValue }.drop(1).collect { value ->
            val selected = value == DrawerValue.Open
            if (selected != modelOpen) latestContext.emit(if (selected) "open" else "close")
        }
    }

    val colors = MaterialTheme.colorScheme
    val dark = LocalLuiThemeDark.current ?: androidx.compose.foundation.isSystemInDarkTheme()
    BoxWithConstraints(Modifier.fillMaxSize().testTag("application.shell")) {
        val width = minOf((context.int("width") ?: 320).dp, maxWidth * 0.80f)
        val widthPx = with(LocalDensity.current) { width.toPx() }.coerceAtLeast(1f)
        val slidePx = with(LocalDensity.current) { 38.dp.toPx() }.coerceAtMost(widthPx)
        val direction = if (LocalLayoutDirection.current == LayoutDirection.Ltr) 1f else -1f
        fun revealFraction(): Float {
            val offset = drawer.currentOffset
            return if (offset.isFinite()) (1f + offset / widthPx).coerceIn(0f, 1f)
            else if (open) 1f else 0f
        }
        fun sidebarTranslation(progress: Float) = direction * (progress - 1f) * slidePx
        ModalNavigationDrawer(
            drawerState = drawer,
            gesturesEnabled = enabled || open,
            scrimColor = Color.Transparent,
            drawerContent = {
                ModalDrawerSheet(
                    drawerState = drawer,
                    drawerShape = RectangleShape,
                    drawerContainerColor = Color.Transparent,
                    modifier = Modifier.width(width).graphicsLayer {
                        val progress = revealFraction()
                        alpha = progress
                        // Keep the closed sheet offscreen for Material's hit testing.
                        translationX = if (progress > 0f) {
                            sidebarTranslation(progress) + direction * (1f - progress) * widthPx
                        } else 0f
                    }.then(if (!open) Modifier.semantics { hideFromAccessibility() } else Modifier),
                ) {
                    // Rows share the drawer's backdrop while retaining their selected semantics.
                    MaterialTheme(colorScheme = colors.copy(
                        surface = Color.Transparent,
                        secondaryContainer = Color.Transparent,
                        onSecondaryContainer = colors.onSurface,
                    )) { context.child(panel) }
                }
            },
        ) {
            val progress = revealFraction()
            val obscured = open || progress > 0f
            Box(Modifier.fillMaxSize()) {
                CompositionLocalProvider(LocalLuiScrollingEnabled provides !obscured) {
                    Box(
                        Modifier.fillMaxSize().blur(20.dp * progress)
                            .then(if (obscured) Modifier.semantics { hideFromAccessibility() } else Modifier),
                    ) { context.child(main) }
                }
                Canvas(Modifier.fillMaxSize()) {
                    drawRect(colors.background.copy(alpha = revealFraction() * if (dark) 0.72f else 0.86f))
                }
            }
        }
        val progress = revealFraction()
        if (progress > 0f) {
            Box(Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 16.dp)
                .graphicsLayer {
                    val reveal = revealFraction()
                    alpha = reveal
                    translationX = sidebarTranslation(reveal)
                }
                .then(if (!open) Modifier.semantics { hideFromAccessibility() } else Modifier),
            ) { context.child(settings) }
        }
    }
}
