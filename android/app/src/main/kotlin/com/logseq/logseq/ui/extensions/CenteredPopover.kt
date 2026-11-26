package com.logseq.logseq.ui.extensions

import android.view.WindowManager
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenuGroup
import androidx.compose.material3.DropdownMenuPopup
import androidx.compose.material3.DropdownMenuPopupPositionProvider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MenuAnchorPosition
import androidx.compose.material3.MenuDefaults
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.window.PopupProperties
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionRegistry

@OptIn(ExperimentalMaterial3Api::class)
internal fun LuiExtensionRegistry.registerCenteredPopover() {
    register(
        identifier = "centered-popover",
        fingerprint = "lui-extension-v1|16:centered-popover|profiles:android/kotlin|" +
            "standard-children:1|children:|properties:|events:7:dismiss[]",
        acceptsStandardChildren = true,
        events = listOf(LuiExtensionEventSchema("dismiss")),
    ) {
        Box {
            children.firstOrNull()?.let { child(it) }
            children.getOrNull(1)?.let { menu ->
                val below = MenuDefaults.rememberDropdownMenuPopupPositionProvider(MenuAnchorPosition.Below)
                val position = remember(below) { CenteredPopoverPosition(below) }
                DropdownMenuPopup(
                    expanded = true,
                    onDismissRequest = { emit("dismiss") },
                    popupPositionProvider = position,
                    properties = PopupProperties(
                        flags = WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
                            WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
                    ),
                ) {
                    DropdownMenuGroup(
                        shapes = MenuDefaults.groupShapes(),
                        modifier = Modifier.verticalScroll(rememberScrollState()),
                    ) {
                        child(menu)
                    }
                }
            }
        }
    }
}

private class CenteredPopoverPosition(
    private val below: DropdownMenuPopupPositionProvider,
) : DropdownMenuPopupPositionProvider {
    override val transformOrigin: TransformOrigin
        get() = TransformOrigin(0.5f, below.transformOrigin.pivotFractionY)

    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val position = below.calculatePosition(anchorBounds, windowSize, layoutDirection, popupContentSize)
        val left = ((windowSize.width - popupContentSize.width) / 2).coerceAtLeast(0)
        return position.copy(x = left)
    }
}
