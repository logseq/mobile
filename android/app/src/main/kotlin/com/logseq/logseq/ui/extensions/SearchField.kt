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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import dev.lui.luiThemeColor

@Composable
private fun searchContainerColor() =
    luiThemeColor("task-tab-background", foreground = false)
        ?: MaterialTheme.colorScheme.surfaceContainerHighest

@Composable
internal fun SearchDismissButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    FilledIconButton(
        onClick = onClick,
        modifier = modifier.size(44.dp),
        shape = CircleShape,
        colors = IconButtonDefaults.filledIconButtonColors(
            containerColor = searchContainerColor(),
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
    ) {
        Icon(Icons.Filled.Close, contentDescription = label, modifier = Modifier.size(20.dp))
    }
}

@Composable
internal fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    label: String,
    clearLabel: String,
    identifier: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    var draft by remember { mutableStateOf(query) }
    val pending = remember { mutableSetOf<String>() }
    LaunchedEffect(query) {
        // Earlier core echoes can arrive while the user is still typing.
        if (!pending.remove(query) && draft != query) {
            draft = query
            pending.clear()
        }
    }
    val colors = MaterialTheme.colorScheme
    val foreground = colors.onSurface.copy(alpha = if (enabled) 1f else 0.38f)
    val secondary = colors.onSurfaceVariant
    val background = searchContainerColor()
    val keyboard = LocalSoftwareKeyboardController.current
    val update = { value: String ->
        draft = value
        pending.add(value)
        onQueryChange(value)
    }
    BasicTextField(
        value = draft,
        onValueChange = update,
        enabled = enabled,
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = foreground),
        cursorBrush = SolidColor(colors.primary),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }),
        modifier = modifier.fillMaxWidth().height(44.dp).testTag(identifier).semantics {
            contentDescription = label
        },
        decorationBox = { field ->
            Row(
                modifier = Modifier.fillMaxWidth().background(background, CircleShape).padding(start = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Search, null, Modifier.size(20.dp), tint = secondary)
                val canClear = draft.isNotEmpty() && enabled
                Box(Modifier.weight(1f).padding(start = 8.dp, end = if (canClear) 0.dp else 12.dp)) {
                    if (draft.isEmpty()) {
                        Text(
                            placeholder,
                            color = secondary,
                            style = MaterialTheme.typography.bodyLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    field()
                }
                if (canClear) {
                    IconButton(
                        onClick = { update("") },
                        modifier = Modifier.size(44.dp).testTag("$identifier.clear"),
                    ) {
                        Box(
                            Modifier.size(18.dp).background(secondary, CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.Close, clearLabel, Modifier.size(12.dp), tint = background)
                        }
                    }
                }
            }
        },
    )
}

internal fun LuiExtensionRegistry.registerFilterSearchField() {
    register(
        identifier = "filter-search-field",
        fingerprint = "lui-extension-v1|19:filter-search-field|profiles:android/kotlin|" +
            "standard-children:0|children:|properties:9:autofocus:bool:required:none," +
            "11:clear-title:string:required:none,8:disabled:bool:required:none,10:identifier:string:required:none," +
            "5:label:string:required:none,11:placeholder:string:required:none,5:query:string:required:none|" +
            "events:13:query-changed[5:query:string:required]",
        properties = listOf(
            LuiExtensionProperty("autofocus", LuiExtensionValueKind.BOOLEAN, required = true),
            LuiExtensionProperty("clear-title", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("disabled", LuiExtensionValueKind.BOOLEAN, required = true),
            LuiExtensionProperty("identifier", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("label", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("placeholder", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("query", LuiExtensionValueKind.STRING, required = true),
        ),
        events = listOf(LuiExtensionEventSchema("query-changed", listOf(
            LuiExtensionProperty("query", LuiExtensionValueKind.STRING, required = true),
        ))),
    ) {
        val focus = remember { FocusRequester() }
        val keyboard = LocalSoftwareKeyboardController.current
        val autofocus = flag("autofocus")
        val enabled = !flag("disabled")
        LaunchedEffect(autofocus, enabled) {
            if (autofocus && enabled) {
                focus.requestFocus()
                keyboard?.show()
            }
        }
        SearchField(
            query = string("query").orEmpty(),
            onQueryChange = { emit("query-changed", "query" to it) },
            placeholder = string("placeholder").orEmpty(),
            label = string("label").orEmpty(),
            clearLabel = string("clear-title").orEmpty(),
            identifier = string("identifier").orEmpty(),
            modifier = Modifier.focusRequester(focus),
            enabled = enabled,
        )
    }
}
