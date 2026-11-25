package com.logseq.logseq.ui.extensions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.logseq.logseq.runtime.logseqIconResolver
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import dev.lui.luiThemeColor

internal fun LuiExtensionRegistry.registerReactionSearchInput() {
    register(
        "reaction-search-input",
        "lui-extension-v1|21:reaction-search-input|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|" +
            "properties:11:clear-title:string:required:none,11:placeholder:string:required:none|events:13:query-changed[5:query:string:required]",
        properties = listOf(
            LuiExtensionProperty("clear-title", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("placeholder", LuiExtensionValueKind.STRING, required = true),
        ),
        events = listOf(LuiExtensionEventSchema("query-changed", listOf(
            LuiExtensionProperty("query", LuiExtensionValueKind.STRING, required = true),
        ))),
    ) {
        val placeholder = string("placeholder").orEmpty()
        val clearTitle = string("clear-title").orEmpty()
        var query by remember { mutableStateOf("") }
        val update = { value: String ->
            query = value
            emit("query-changed", "query" to value)
        }
        val keyboard = LocalSoftwareKeyboardController.current
        val background = luiThemeColor("task-tab-background", foreground = false)
            ?: MaterialTheme.colorScheme.surfaceContainerHighest
        val foreground = MaterialTheme.colorScheme.onSurface
        val secondary = MaterialTheme.colorScheme.onSurfaceVariant

        BasicTextField(
            value = query,
            onValueChange = update,
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(color = foreground),
            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }),
            modifier = Modifier.fillMaxWidth().height(44.dp).testTag("reaction.search").semantics {
                contentDescription = placeholder
            },
            decorationBox = { field ->
                Row(
                    modifier = Modifier.fillMaxWidth().background(background, CircleShape).padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    logseqIconResolver.icon("search")?.let {
                        Icon(it, contentDescription = null, tint = secondary, modifier = Modifier.size(18.dp))
                    }
                    Box(Modifier.weight(1f).padding(start = 8.dp)) {
                        if (query.isEmpty()) {
                            Text(placeholder, color = secondary, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                        }
                        field()
                    }
                    if (query.isNotEmpty()) {
                        IconButton(onClick = { update("") }, modifier = Modifier.size(32.dp)) {
                            logseqIconResolver.icon("close")?.let {
                                Icon(it, contentDescription = clearTitle, tint = secondary, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            },
        )
    }
}
