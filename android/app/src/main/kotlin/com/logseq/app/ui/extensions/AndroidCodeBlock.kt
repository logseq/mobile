package com.logseq.app.ui.extensions

import android.util.LruCache
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.logseq.app.NativeCore
import org.json.JSONArray
import org.json.JSONObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal val LocalShowCodeLanguage = staticCompositionLocalOf { true }

private data class CodeKey(val code: String, val language: String, val dark: Boolean, val background: Int)
private val codeCache = object : LruCache<CodeKey, AnnotatedString>(512 * 1024) {
    override fun sizeOf(key: CodeKey, value: AnnotatedString) =
        key.code.length * 2 + value.spanStyles.size * 64 + 128
}
private val codeDispatcher = Dispatchers.Default.limitedParallelism(1)

private fun highlightedCode(key: CodeKey): AnnotatedString {
    codeCache.get(key)?.let { return it }
    if (key.language in listOf("", "plaintext", "text", "calc") || key.code.isEmpty() || key.code.length > 100_000) return AnnotatedString(key.code)
    val request = JSONObject().put("text", key.code).put("language", key.language).toString()
    val highlights = runCatching {
        JSONArray(NativeCore.highlightCode(request.toByteArray(Charsets.UTF_8))?.toString(Charsets.UTF_8) ?: "[]")
    }.getOrElse { JSONArray() }
    val background = Color(key.background).luminance()
    val readableColors = mutableMapOf<Int, Color>()
    return buildAnnotatedString {
        append(key.code)
        for (index in 0 until highlights.length()) {
            val highlight = highlights.getJSONArray(index)
            val start = highlight.getInt(0)
            val end = highlight.getInt(1)
            if (start < 0 || end <= start || end > length) continue
            val rgb = syntaxColor(highlight.getString(2), key.dark)
            val style = SpanStyle(color = readableColors.getOrPut(rgb) {
                val original = Color(rgb or 0xff000000.toInt())
                val target = if (background > .179f) Color.Black else Color.White
                (0..10).asSequence().map { lerp(original, target, it / 10f) }.first { color ->
                    val foreground = color.luminance()
                    (maxOf(foreground, background) + .05f) / (minOf(foreground, background) + .05f) >= 4.5f
                }
            })
            addStyle(style, start, end)
        }
    }.also { codeCache.put(key, it) }
}

private fun syntaxColor(style: String, dark: Boolean): Int = when (style.substringBefore(' ')) {
    "keyword", "operator", "tag", "error" -> if (dark) 0xff7b72 else 0xcf222e
    "atom", "number", "attribute", "meta", "link" -> if (dark) 0x79c0ff else 0x0550ae
    "def", "type", "variable-3" -> if (dark) 0xd2a8ff else 0x8250df
    "string", "string-2" -> if (dark) 0xa5d6ff else 0x0a3069
    "comment" -> if (dark) 0x8b949e else 0x57606a
    "builtin", "variable-2", "qualifier" -> if (dark) 0xffa657 else 0x953800
    else -> if (dark) 0xc9d1d9 else 0x24292f
}

@Composable
internal fun rememberHighlightedCode(code: String, language: String): AnnotatedString {
    val dark = MaterialTheme.colorScheme.surface.luminance() < .5f
    val key = CodeKey(code, language.trim().lowercase(), dark, MaterialTheme.colorScheme.surfaceContainerHigh.toArgb())
    var annotated by remember(key) { mutableStateOf(codeCache.get(key) ?: AnnotatedString(code)) }
    LaunchedEffect(key) {
        annotated = withContext(codeDispatcher) { highlightedCode(key) }
    }
    return annotated
}

@Composable
internal fun AndroidCodeBlock(code: String, language: String) {
    val annotated = rememberHighlightedCode(code, language)
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = if (LocalShowCodeLanguage.current) MaterialTheme.colorScheme.surfaceContainerHigh else Color.Transparent,
        modifier = Modifier.fillMaxWidth().testTag("block.rich.code"),
    ) {
        Column(Modifier.padding(12.dp)) {
            if (LocalShowCodeLanguage.current && language.isNotBlank()) {
                Text(language, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(bottom = 6.dp))
            }
            Text(
                annotated,
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                softWrap = false,
            )
        }
    }
}
