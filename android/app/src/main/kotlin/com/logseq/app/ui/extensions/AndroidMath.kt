package com.logseq.app.ui.extensions

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import ru.noties.jlatexmath.JLatexMathAndroid
import ru.noties.jlatexmath.JLatexMathDrawable

private data class FormulaKey(val source: String, val size: Float, val color: Int)

// TeX font/parser initialization uses global library state. Keep parsing and
// drawing on one worker, away from Compose measurement and the UI thread.
private val formulaDispatcher = Dispatchers.Default.limitedParallelism(1)
private val formulaCache = object : LruCache<FormulaKey, Bitmap>(8 * 1024 * 1024) {
    override fun sizeOf(key: FormulaKey, value: Bitmap) = value.allocationByteCount
}

private fun renderFormula(context: Context, key: FormulaKey): Bitmap? {
    formulaCache.get(key)?.let { return it }
    if (key.source.isBlank() || key.source.length > 4096) return null
    return try {
        JLatexMathAndroid.init(context)
        val drawable = JLatexMathDrawable.builder(key.source)
            .textSize(key.size).color(key.color).padding(2).build()
        val width = drawable.intrinsicWidth
        val height = drawable.intrinsicHeight
        // Keep pathological expressions readable without allocating huge images.
        if (width <= 0 || height <= 0 || width > 16_384 || height > 4096 || width.toLong() * height > 2_000_000) {
            null
        } else {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                drawable.draw(Canvas(it))
                formulaCache.put(key, it)
            }
        }
    } catch (_: Exception) {
        null
    }
}

@Composable
internal fun rememberFormulaBitmap(expression: String, size: Float): Bitmap? {
    val context = LocalContext.current.applicationContext
    val key = FormulaKey(expression, size, MaterialTheme.colorScheme.onSurface.toArgb())
    var bitmap by remember(key) { mutableStateOf(formulaCache.get(key)) }
    LaunchedEffect(key) { bitmap = withContext(formulaDispatcher) { renderFormula(context, key) } }
    return bitmap
}

@Composable
internal fun AndroidMath(expression: String) {
    val density = LocalDensity.current
    val size = with(density) { MaterialTheme.typography.bodyLarge.fontSize.toPx() }
    val bitmap = rememberFormulaBitmap(expression, size)
    Box(Modifier.padding(vertical = 4.dp).horizontalScroll(rememberScrollState())) {
        val rendered = bitmap
        if (rendered == null) {
            Text(expression, style = MaterialTheme.typography.bodyLarge)
        } else {
            Image(
                bitmap = rendered.asImageBitmap(),
                contentDescription = expression,
                modifier = Modifier.size(
                    with(density) { rendered.width.toDp() },
                    with(density) { rendered.height.toDp() },
                ).testTag("block.rich.math.rendered"),
            )
        }
    }
}
