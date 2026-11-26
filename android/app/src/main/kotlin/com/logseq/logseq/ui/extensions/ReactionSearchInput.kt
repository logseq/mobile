package com.logseq.logseq.ui.extensions

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind

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
        var query by remember { mutableStateOf("") }
        SearchField(
            query = query,
            onQueryChange = { value ->
                query = value
                emit("query-changed", "query" to value)
            },
            placeholder = placeholder,
            label = placeholder,
            clearLabel = string("clear-title").orEmpty(),
            identifier = "reaction.search",
        )
    }
}
