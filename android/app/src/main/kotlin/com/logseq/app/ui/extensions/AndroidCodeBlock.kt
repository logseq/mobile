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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.snipme.highlights.Highlights
import dev.snipme.highlights.model.BoldHighlight
import dev.snipme.highlights.model.ColorHighlight
import dev.snipme.highlights.model.SyntaxLanguage
import dev.snipme.highlights.model.SyntaxThemes
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
    val language = SyntaxLanguage.getByName(key.language)
    if (language == null || key.code.length > 100_000) return AnnotatedString(key.code)
    val theme = SyntaxThemes.atom(key.dark)
    val highlights = Highlights.Builder().code(key.code).language(language).theme(theme).build().getHighlights()
    val background = Color(key.background).luminance()
    val readableColors = mutableMapOf<Int, Color>()
    return buildAnnotatedString {
        append(key.code)
        for (highlight in highlights) {
            val start = highlight.location.start.coerceIn(0, length)
            val end = highlight.location.end.coerceIn(start, length)
            val style = when (highlight) {
                is ColorHighlight -> SpanStyle(color = readableColors.getOrPut(highlight.rgb) {
                    val original = Color(highlight.rgb or 0xff000000.toInt())
                    val target = if (background > .179f) Color.Black else Color.White
                    (0..10).asSequence().map { lerp(original, target, it / 10f) }.first { color ->
                        val foreground = color.luminance()
                        (maxOf(foreground, background) + .05f) / (minOf(foreground, background) + .05f) >= 4.5f
                    }
                })
                is BoldHighlight -> SpanStyle(fontWeight = FontWeight.Bold)
            }
            if (end > start) addStyle(style, start, end)
        }
    }.also { codeCache.put(key, it) }
}

@Composable
internal fun AndroidCodeBlock(code: String, language: String) {
    val dark = MaterialTheme.colorScheme.surface.luminance() < .5f
    val key = CodeKey(code, language.trim().lowercase(), dark, MaterialTheme.colorScheme.surfaceContainerHigh.toArgb())
    var annotated by remember(key) { mutableStateOf(codeCache.get(key) ?: AnnotatedString(code)) }
    LaunchedEffect(key) {
        annotated = withContext(codeDispatcher) { highlightedCode(key) }
    }
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
