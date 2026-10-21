package com.logseq.app.ui.extensions

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.logseq.app.AndroidAudioPlayer
import com.logseq.app.runtime.AndroidLaunchMetrics
import dev.lui.LuiExtensionContext
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

// Port of _OutlinerBlockContent + markup/asset/embedded hosts from
// the former logseq_extensions.dart, android_audio_playback.dart,
// android_embedded_media.dart, android_math.dart, android_cloze.dart.

// Block text matches iOS `.body` (17pt, ~22pt leading).
private val outlinerBodyStyle: androidx.compose.ui.text.TextStyle
    @Composable get() = MaterialTheme.typography.bodyLarge.copy(
        fontSize = 17.sp,
        lineHeight = 22.sp,
    )

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun OutlinerBlockContent(
    context: LuiExtensionContext,
    resolveAssetPath: (String) -> String,
    youtubeStarts: MutableMap<String, Int>,
    onOpenImage: ((String, String) -> Unit)? = null,
) {
    val uuid = context.string("block-id") ?: ""
    val title = context.string("title") ?: ""
    val completed = context.flag("is-completed")
    val isAsset = context.flag("is-asset")

    var rowHeightPx by remember { mutableIntStateOf(0) }
    var rowPosition by remember { mutableStateOf(Offset.Zero) }
    val density = LocalDensity.current.density
    var hoverPlacement by remember { mutableStateOf("after") }
    var dragHover by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }
    val hoverColor by animateColorAsState(
        if (dragHover) MaterialTheme.colorScheme.primaryContainer else Color.Transparent,
        label = "dropHighlight",
    )

    val dropTarget = remember(uuid, density) {
        object : DragAndDropTarget {
            private fun placement(event: DragAndDropEvent): String {
                val drag = event.toAndroidDragEvent()
                return outlinerDropPlacement(
                    (drag.y - rowPosition.y) / density,
                    rowHeightPx / density,
                    (drag.x - rowPosition.x) / density,
                )
            }
            override fun onDrop(event: DragAndDropEvent): Boolean {
                dragHover = false
                val clip = event.toAndroidDragEvent().clipData
                val source = clip?.takeIf { it.itemCount > 0 }
                    ?.getItemAt(0)?.text?.toString() ?: return false
                if (source == uuid) return false
                context.emit(
                    "drop",
                    "uuid" to uuid,
                    "placement" to placement(event),
                )
                return true
            }

            override fun onEntered(event: DragAndDropEvent) {
                dragHover = true
                hoverPlacement = placement(event)
            }

            override fun onMoved(event: DragAndDropEvent) {
                hoverPlacement = placement(event)
            }

            override fun onExited(event: DragAndDropEvent) {
                dragHover = false
            }

            override fun onEnded(event: DragAndDropEvent) {
                dragHover = false
            }
        }
    }

    val decoration = if (completed) TextDecoration.LineThrough else null
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .onGloballyPositioned {
                rowHeightPx = it.size.height
                rowPosition = it.positionInRoot()
                // First placed block ≈ first frame with real journal content.
                AndroidLaunchMetrics.report("journals_ui_ready")
            }
            .background(hoverColor, RoundedCornerShape(8.dp))
            .dragAndDropSource(
                drawDragDecoration = {},
                block = {
                    detectTapGestures(
                        onTap = {
                            context.emit("edit", "uuid" to uuid)
                        },
                        onLongPress = {
                            dragging = true
                            context.emit("drag-start", "uuid" to uuid)
                            startTransfer(
                                DragAndDropTransferData(
                                    android.content.ClipData.newPlainText("block", uuid),
                                )
                            )
                            dragging = false
                        },
                    )
                },
            )
            .dragAndDropTarget(
                shouldStartDragAndDrop = { true },
                target = dropTarget,
            )
            .testTag("outliner-block-content-$uuid"),
    ) {
        Column(modifier = Modifier.alpha(if (dragging) 0.35f else 1f)) {
            if (isAsset) {
                ProjectedAsset(
                    title = title,
                    assetType = context.string("asset-type") ?: "",
                    localPath = resolveAssetPath(context.string("local-path") ?: ""),
                    onPreview = onOpenImage?.let { open ->
                        { open(uuid, resolveAssetPath(context.string("local-path") ?: "")) }
                    },
                )
            } else {
                ProjectedMarkup(
                    youtubeStarts = youtubeStarts,
                    encoded = context.string("markup-json") ?: "",
                    fallback = title,
                    completedDecoration = decoration,
                    onOpenNode = { context.emit("open-node", "uuid" to it) },
                    onTapFallback = { context.emit("edit", "uuid" to uuid) },
                )
            }
        }
        if (dragHover) {
            val indicator = MaterialTheme.colorScheme.primary
            Canvas(Modifier.matchParentSize().testTag("outliner.drop.$hoverPlacement")) {
                val y = if (hoverPlacement == "before") 1.dp.toPx() else size.height - 1.dp.toPx()
                val start = if (hoverPlacement == "inside") 20.dp.toPx() else 0f
                drawLine(indicator, Offset(start, y), Offset(size.width, y), strokeWidth = 2.dp.toPx())
                drawCircle(indicator, radius = 3.dp.toPx(), center = Offset(start + 3.dp.toPx(), y))
            }
        }
    }
}

internal fun outlinerDropPlacement(localY: Float, rowHeight: Float, localX: Float = 0f): String {
    val height = if (rowHeight <= 0) 1f else rowHeight
    return when {
        localY < minOf(16f, height * 0.25f) -> "before"
        localX > 100f -> "inside"
        else -> "after"
    }
}

// --- markup-json ---

@Composable
private fun ProjectedMarkup(
    youtubeStarts: MutableMap<String, Int>,
    encoded: String,
    fallback: String,
    completedDecoration: TextDecoration?,
    onOpenNode: (String) -> Unit,
    onTapFallback: () -> Unit,
) {
    val nodes = remember(encoded) { decodeMarkup(encoded) }
    if (nodes.isEmpty()) {
        Text(
            fallback,
            style = outlinerBodyStyle.copy(
                textDecoration = completedDecoration
            ),
        )
        return
    }
    val chunks = remember(nodes) { markupChunks(nodes) }
    if (chunks.size == 1) {
        MarkupChunk(chunks.single(), 0, completedDecoration, onOpenNode, onTapFallback, youtubeStarts)
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            for ((index, chunk) in chunks.withIndex()) {
                MarkupChunk(chunk, index, completedDecoration, onOpenNode, onTapFallback, youtubeStarts)
            }
        }
    }
}

@Composable
private fun MarkupChunk(
    chunk: List<JSONObject>,
    index: Int,
    completedDecoration: TextDecoration?,
    onOpenNode: (String) -> Unit,
    onTapFallback: () -> Unit,
    youtubeStarts: MutableMap<String, Int>,
) {
    if (chunk.size == 1 && isRichNode(chunk.first())) {
        MarkupRichNode(chunk.first(), completedDecoration, onOpenNode, onTapFallback, youtubeStarts)
    } else {
        val annotated = remember(chunk, completedDecoration) {
            markupAnnotatedString(chunk, completedDecoration)
        }
        MarkupInlineText(
            annotated = annotated,
            modifier = Modifier.fillMaxWidth().testTag("block.rich.inline.$index"),
            onOpenNode = onOpenNode,
            onTapFallback = onTapFallback,
        )
    }
}

private fun decodeMarkup(encoded: String): List<JSONObject> {
    if (encoded.isBlank()) return emptyList()
    return try {
        val array = JSONArray(encoded)
        (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    } catch (_: Throwable) {
        emptyList()
    }
}

private fun isRichNode(node: JSONObject): Boolean = node.optString("type") in setOf(
    "quote", "math", "codeBlock", "video", "iframe", "youtubeTimestamp", "cloze",
)

private fun markupChunks(nodes: List<JSONObject>): List<List<JSONObject>> {
    val result = mutableListOf<List<JSONObject>>()
    var inline = mutableListOf<JSONObject>()
    for (node in nodes) {
        if (isRichNode(node)) {
            if (inline.isNotEmpty()) result.add(inline)
            inline = mutableListOf()
            result.add(listOf(node))
        } else {
            inline.add(node)
        }
    }
    if (inline.isNotEmpty()) result.add(inline)
    return result
}

private const val TAG_NODE = "lui.node"
private const val TAG_URL = "lui.url"
private const val TAG_TIMESTAMP = "lui.timestamp"

private fun markupAnnotatedString(
    nodes: List<JSONObject>,
    decoration: TextDecoration?,
): AnnotatedString = buildAnnotatedString {
    for (node in nodes) appendNode(node, decoration)
}

private fun AnnotatedString.Builder.appendNode(node: JSONObject, decoration: TextDecoration?) {
    when (node.optString("type")) {
        "text" -> withStyle(SpanStyle(textDecoration = decoration)) {
            append(node.optString("text"))
        }
        "emphasis" -> {
            val style = when (node.optString("style")) {
                "bold" -> SpanStyle(fontWeight = FontWeight.Bold)
                "italic" -> SpanStyle(fontStyle = FontStyle.Italic)
                "underline" -> SpanStyle(textDecoration = TextDecoration.Underline)
                "strikeThrough" -> SpanStyle(textDecoration = TextDecoration.LineThrough)
                else -> SpanStyle()
            }
            val combined = listOfNotNull(decoration, style.textDecoration)
                .takeIf { it.isNotEmpty() }?.let(TextDecoration::combine)
            withStyle(style.copy(textDecoration = combined)) {
                appendChildren(node, combined)
            }
        }
        "code" -> withStyle(
            SpanStyle(
                fontFamily = FontFamily.Monospace,
                background = Color(0x33000000),
            )
        ) { append(node.optString("text")) }
        "nodeReference", "tagReference" -> {
            val uuid = node.optString("uuid")
            val label = node.optString("title").ifEmpty { uuid }
            withStyle(
                SpanStyle(
                    color = Color(0xff2d6cdf),
                    fontWeight = FontWeight.Medium,
                )
            ) {
                pushStringAnnotation(TAG_NODE, uuid)
                append(if (node.optString("type") == "nodeReference") "[[$label]]" else "#$label")
                pop()
            }
        }
        "link" -> {
            val url = node.optString("url")
            val children = node.optJSONArray("children")
            pushStringAnnotation(TAG_URL, url)
            withStyle(SpanStyle(color = Color(0xff2d6cdf))) {
                if (children != null && children.length() > 0) {
                    for (i in 0 until children.length()) {
                        children.optJSONObject(i)?.let { appendNode(it, decoration) }
                    }
                } else {
                    append(url)
                }
            }
            pop()
        }
        "youtubeTimestamp" -> {
            val seconds = node.optString("style")
            pushStringAnnotation(TAG_TIMESTAMP, node.optString("embedURL"))
            withStyle(
                SpanStyle(
                    color = Color(0xff2d6cdf),
                    fontFamily = FontFamily.Monospace,
                )
            ) {
                append(node.optString("text").ifEmpty { seconds })
            }
            pop()
        }
        "math" -> append(node.optString("text"))
        else -> appendChildren(node, decoration)
    }
}

private fun AnnotatedString.Builder.appendChildren(node: JSONObject, decoration: TextDecoration?) {
    val children = node.optJSONArray("children")
    if (children == null) {
        append(node.optString("text"))
    } else {
        for (index in 0 until children.length()) {
            children.optJSONObject(index)?.let { appendNode(it, decoration) }
        }
    }
}

@Composable
private fun MarkupInlineText(
    annotated: AnnotatedString,
    modifier: Modifier,
    onOpenNode: (String) -> Unit,
    onTapFallback: () -> Unit,
    textStyle: TextStyle? = null,
) {
    val context = LocalContext.current
    val openNode by rememberUpdatedState(onOpenNode)
    val edit by rememberUpdatedState(onTapFallback)
    val linked = remember(annotated, context) {
        val links = annotated.getStringAnnotations(0, annotated.length)
        if (links.isEmpty()) annotated else AnnotatedString.Builder(annotated).apply {
            for (link in links) {
                addLink(LinkAnnotation.Clickable(link.tag, linkInteractionListener = {
                    when (link.tag) {
                        TAG_NODE -> openNode(link.item)
                        TAG_URL, TAG_TIMESTAMP -> openExternalUrl(context, link.item)
                        else -> edit()
                    }
                }), link.start, link.end)
            }
        }.toAnnotatedString()
    }
    // Native text links avoid ClickableText's layout-result state update on
    // every newly composed row, and expose link/edit actions to accessibility.
    Text(
        text = linked,
        style = textStyle ?: outlinerBodyStyle.copy(
            color = MaterialTheme.colorScheme.onSurface
        ),
        modifier = modifier.clickable(onClick = onTapFallback),
    )
}

@Composable
private fun MarkupRichNode(
    node: JSONObject,
    completedDecoration: TextDecoration?,
    onOpenNode: (String) -> Unit,
    onTapFallback: () -> Unit,
    youtubeStarts: MutableMap<String, Int>,
) {
    when (node.optString("type")) {
        "quote" -> {
            val annotated = remember(node, completedDecoration) {
                buildAnnotatedString { appendChildren(node, completedDecoration) }
            }
            val border = MaterialTheme.colorScheme.outlineVariant
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 2.dp)
                    .drawBehind {
                        drawLine(border, Offset.Zero, Offset(0f, size.height), strokeWidth = 3.dp.toPx())
                    },
            ) {
                MarkupInlineText(
                    annotated = annotated,
                    modifier = Modifier.padding(start = 13.dp),
                    onOpenNode = onOpenNode,
                    onTapFallback = onTapFallback,
                    textStyle = outlinerBodyStyle.copy(
                        fontStyle = FontStyle.Italic,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    ),
                )
            }
        }
        "math" -> AndroidMath(node.optString("text"))
        "codeBlock" -> AndroidCodeBlock(
            code = node.optString("text"),
            language = node.optString("style"),
        )
        "video" -> {
            val original = node.optString("embedURL").ifEmpty { node.optString("url") }
            val start = youtubeStarts[node.optString("url")]
            val uri = androidEmbeddedMediaUri(original)
            val url = if (start == null || uri == null) original else {
                uri.buildUpon().clearQuery().apply {
                    for (key in uri.queryParameterNames.filter { it != "start" }) {
                        uri.getQueryParameters(key).forEach { appendQueryParameter(key, it) }
                    }
                    appendQueryParameter("start", start.toString())
                }.build().toString()
            }
            AndroidEmbeddedMedia(url = url, isVideo = true, headers = mediaHeaders(node))
        }
        "iframe" -> AndroidEmbeddedMedia(url = node.optString("embedURL"), isVideo = false, headers = mediaHeaders(node))
        "youtubeTimestamp" -> {
            val target = node.optString("url")
            val seconds = node.optInt("seconds", -1)
            TextButton(onClick = { youtubeStarts[target] = seconds },
                enabled = androidEmbeddedMediaUri(target) != null && seconds >= 0) {
                Text("◷ " + node.optString("text"))
            }
        }
        "cloze" -> AndroidCloze(node.optString("text"))
        else -> Text(node.optString("text"), style = outlinerBodyStyle)
    }
}

// --- assets ---

@Composable
private fun ProjectedAsset(title: String, assetType: String, localPath: String, onPreview: (() -> Unit)?) {
    when {
        isImageAsset(assetType, localPath) && localPath.isNotEmpty() -> {
            val bitmap = remember(localPath) {
                runCatching { BitmapFactory.decodeFile(localPath)?.asImageBitmap() }.getOrNull()
            }
            if (bitmap != null) {
                Image(
                    bitmap = bitmap,
                    contentDescription = title,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .then(if (onPreview != null) Modifier.clickable(onClick = onPreview) else Modifier)
                        .testTag("asset.preview.image"),
                    contentScale = ContentScale.FillWidth,
                )
            } else {
                AssetFallback(title)
            }
        }
        localPath.isNotEmpty() && isAudioAsset(assetType, localPath) ->
            AndroidAudioPlaybackRow(title = title, path = localPath)
        else -> AssetFallback(title)
    }
}

@Composable
private fun AssetFallback(title: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Add, contentDescription = null)
        Text(title, modifier = Modifier.padding(start = 8.dp))
    }
}

internal fun isImageAsset(assetType: String, localPath: String): Boolean {
    val normalized = assetType.lowercase().split(";").first().trim()
    if (normalized.startsWith("image/")) return true
    val extensions = setOf(
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "wbmp", "heic", "heif", "avif",
    )
    if (normalized in extensions) return true
    val dot = localPath.lastIndexOf('.')
    if (dot < 0 || dot == localPath.length - 1) return false
    return localPath.substring(dot + 1).lowercase() in extensions
}

internal fun isAudioAsset(assetType: String, localPath: String): Boolean {
    val normalized = assetType.lowercase().split(";").first().trim()
    if (normalized.startsWith("audio/")) return true
    val extensions = setOf("m4a", "aac", "mp3", "wav", "ogg", "opus", "flac")
    if (normalized in extensions) return true
    val dot = localPath.lastIndexOf('.')
    if (dot < 0 || dot == localPath.length - 1) return false
    return localPath.substring(dot + 1).lowercase() in extensions
}

// --- audio playback (android_audio_playback.dart) ---

@Composable
private fun AndroidAudioPlaybackRow(title: String, path: String) {
    val context = LocalContext.current
    val activity = context as? android.app.Activity
    val player = remember { AndroidAudioPlayer(activity ?: context as android.app.Activity) }
    var sessionId by remember { mutableIntStateOf(-1) }
    var playing by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }
    var durationMs by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()

    DisposableEffect(Unit) {
        onDispose { player.release() }
    }
    LaunchedEffect(playing, sessionId) {
        while (playing && sessionId >= 0) {
            val status = player.status(sessionId)
            val position = (status["positionMs"] as? Number)?.toInt() ?: 0
            val duration = (status["durationMs"] as? Number)?.toInt() ?: durationMs
            durationMs = duration
            progress = if (duration > 0) position / duration.toFloat() else 0f
            if (status["state"] == "completed" || status["state"] == "stopped") {
                playing = false
                progress = 0f
            }
            delay(200)
        }
    }

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            IconButton(
                onClick = {
                    scope.launch {
                        if (sessionId < 0) {
                            val result = player.start(path)
                            sessionId = (result["sessionId"] as? Number)?.toInt() ?: -1
                            playing = sessionId >= 0
                        } else if (playing) {
                            player.pause(sessionId)
                            playing = false
                        } else {
                            player.resume(sessionId)
                            playing = true
                        }
                    }
                },
                modifier = Modifier.testTag("button.audio.play"),
            ) {
                Icon(
                    if (playing) Icons.Filled.Add else Icons.Filled.PlayArrow,
                    contentDescription = if (playing) "Pause" else "Play",
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = outlinerBodyStyle, maxLines = 1)
                androidx.compose.material3.LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

// --- embedded media / math / cloze / code ---

private fun mediaHeaders(node: JSONObject): Map<String, String> {
    val headers = node.optJSONObject("mediaHeaders") ?: return emptyMap()
    return headers.keys().asSequence().associateWith { headers.getString(it) }
}

internal fun androidEmbeddedMediaUri(value: String): Uri? {
    val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return null
    return uri.takeIf { !value.isBlank() && it.scheme in listOf("http", "https") }
}

@Composable
internal fun AndroidEmbeddedMedia(url: String, isVideo: Boolean, headers: Map<String, String> = emptyMap()) {
    val uri = remember(url) { androidEmbeddedMediaUri(url) }
    if (uri == null) {
        Text(
            if (isVideo) "Invalid video URL" else "Invalid embed URL",
            style = outlinerBodyStyle.copy(
                color = MaterialTheme.colorScheme.onSurfaceVariant
            ),
        )
        return
    }
    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                settings.mediaPlaybackRequiresUserGesture = true
                webViewClient = WebViewClient()
                loadUrl(uri.toString(), headers)
            }
        },
        update = { webView -> if (webView.url != uri.toString()) webView.loadUrl(uri.toString(), headers) },
        modifier = Modifier
            .fillMaxWidth()
            .height(220.dp)
            .clip(RoundedCornerShape(16.dp))
            .testTag("media.webview.loaded"),
    )
}

@Composable
internal fun AndroidCloze(text: String) {
    var revealed by remember { mutableStateOf(false) }
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier
            .testTag("button.cloze.reveal")
            .clickable { revealed = !revealed },
    ) {
        Text(
            if (revealed) text else "Tap to reveal",
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

private fun openExternalUrl(context: android.content.Context, url: String) {
    if (url.isBlank()) return
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    } catch (_: ActivityNotFoundException) {
    }
}
