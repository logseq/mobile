package com.logseq.app.ui.extensions

import android.content.Context
import android.graphics.Typeface
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import org.json.JSONObject

private class NodeIconCatalog(context: Context) {
    val data = context.assets.open("node-icons/node-icons.json").bufferedReader().use { JSONObject(it.readText()) }
    val outline = FontFamily(Typeface.createFromAsset(context.assets, "node-icons/tabler-icons.ttf"))
    val filled = FontFamily(Typeface.createFromAsset(context.assets, "node-icons/tabler-icons-filled.ttf"))
}

private object NodeIconAssets {
    private var catalog: NodeIconCatalog? = null
    @Synchronized fun get(context: Context): NodeIconCatalog =
        catalog ?: NodeIconCatalog(context.applicationContext).also { catalog = it }
}

internal fun LuiExtensionRegistry.registerNodeIcon() {
    register("node-icon",
        "lui-extension-v1|9:node-icon|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:4:size:int:required:none,5:muted:bool:required:none,7:payload:string:required:none|events:",
        properties = listOf(
            LuiExtensionProperty("payload", LuiExtensionValueKind.STRING, required = true),
            LuiExtensionProperty("size", LuiExtensionValueKind.INTEGER, required = true),
            LuiExtensionProperty("muted", LuiExtensionValueKind.BOOLEAN, required = true),
        ), events = emptyList(),
    ) { NodeIcon(string("payload"), int("size") ?: 20, bool("muted") == true) }
}

@Composable
private fun NodeIcon(encoded: String?, size: Int, muted: Boolean) {
    val context = LocalContext.current
    val catalog = remember { NodeIconAssets.get(context) }
    val icon = remember(encoded) { runCatching { JSONObject(encoded ?: "{}") }.getOrDefault(JSONObject()) }
    val id = icon.optString("id")
    val emoji = icon.optString("type") == "emoji"
    val skins = catalog.data.getJSONObject("emoji").optJSONArray(id.trim(':'))
    val glyph = catalog.data.getJSONObject("tabler").optJSONArray(id.lowercase().filter { it in 'a'..'z' || it.isDigit() })
    val text = if (emoji) {
        if (skins != null && skins.length() > 0) skins.optString((icon.optInt("skin", 1) - 1).coerceIn(0, skins.length() - 1))
        else if (id.codePoints().anyMatch { it > 0x2000 }) id else ""
    } else glyph?.let { String(Character.toChars(it.getInt(0))) }.orEmpty()
    val color = if (muted) MaterialTheme.colorScheme.onSurfaceVariant else remember(icon.optString("color")) {
        runCatching { Color(android.graphics.Color.parseColor(icon.getString("color"))) }.getOrNull()
    } ?: MaterialTheme.colorScheme.onSurface
    Box(Modifier.size(size.dp), contentAlignment = Alignment.Center) {
        Text(text, fontSize = size.sp, color = color,
            fontFamily = if (emoji) FontFamily.Default else if (glyph?.optBoolean(1) == true) catalog.filled else catalog.outline)
    }
}
