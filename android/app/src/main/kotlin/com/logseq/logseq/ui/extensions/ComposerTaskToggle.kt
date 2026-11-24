package com.logseq.logseq.ui.extensions

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.logseq.logseq.runtime.logseqIconResolver
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind

internal fun LuiExtensionRegistry.registerComposerTaskToggle() {
    register(
        "composer-task-toggle",
        "lui-extension-v1|20:composer-task-toggle|profiles:android/kotlin|standard-children:0|children:|" +
            "properties:5:label:string:required:none,8:selected:bool:required:none|events:5:press[]",
        properties = listOf(
            LuiExtensionProperty("label", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("selected", LuiExtensionValueKind.BOOLEAN, required = true),
        ),
        events = listOf(LuiExtensionEventSchema("press")),
    ) {
        val isSelected = flag("selected")
        val icon = requireNotNull(logseqIconResolver.icon("app:toolbar-task"))
        val colors = MaterialTheme.colorScheme
        IconButton(
            onClick = { emit("press") },
            modifier = Modifier.size(48.dp).testTag("button.task-status")
                .semantics { selected = isSelected },
            colors = IconButtonDefaults.iconButtonColors(
                contentColor = if (isSelected) colors.primary else colors.onSurfaceVariant,
            ),
        ) {
            Icon(icon, contentDescription = string("label"))
        }
    }
}
