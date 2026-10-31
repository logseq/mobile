package com.logseq.app.ui.extensions

import android.graphics.PointF
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.platform.toClipEntry
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.pdf.ExperimentalPdfApi
import androidx.pdf.Highlight
import androidx.pdf.PdfDocument
import androidx.pdf.PdfRect
import androidx.pdf.SandboxedPdfLoader
import androidx.pdf.compose.PdfViewer
import androidx.pdf.compose.rememberPdfViewerState
import androidx.pdf.content.PageSelection
import androidx.pdf.content.PdfPageTextContent
import androidx.pdf.selection.model.TextSelection
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

internal val LocalOpenPDF = staticCompositionLocalOf<((String, String, String) -> Unit)?> { null }
private val colors = listOf("yellow", "red", "green", "blue", "purple")
// AndroidX multiplies highlights into the page; opaque pastels keep the text readable.
private fun highlightColor(color: String): Int = when (color) {
    "red" -> 0xFFFFBDBD.toInt()
    "green" -> 0xFFC1EDCD.toInt()
    "blue" -> 0xFFBBD7FF.toInt()
    "purple" -> 0xFFE4CDF5.toInt()
    else -> 0xFFFFE795.toInt()
}

internal fun encodePdfHighlight(id: String, page: Int, width: Int, height: Int,
    text: String, rects: List<PdfRect>, color: String): JSONObject {
    require(page > 0 && width > 0 && height > 0 && text.isNotBlank() && rects.isNotEmpty())
    require(color in colors && rects.all { it.pageNum == page - 1 &&
        it.left.isFinite() && it.top.isFinite() && it.right.isFinite() && it.bottom.isFinite() &&
        it.left >= 0 && it.top >= 0 && it.right > it.left && it.bottom > it.top &&
        it.right <= width + 0.01 && it.bottom <= height + 0.01 })
    fun json(rect: PdfRect) = JSONObject().put("x1", rect.left).put("y1", rect.top)
        .put("x2", rect.right).put("y2", rect.bottom).put("width", width).put("height", height)
    val bounding = PdfRect(page - 1, rects.minOf { it.left }, rects.minOf { it.top },
        rects.maxOf { it.right }, rects.maxOf { it.bottom })
    return JSONObject().put("id", id).put("page", page).put("content", JSONObject().put("text", text))
        .put("properties", JSONObject().put("color", color))
        .put("position", JSONObject().put("page", page).put("bounding", json(bounding))
            .put("rects", JSONArray(rects.map(::json))))
}

internal fun decodePdfRect(rect: JSONObject, page: Int, width: Int, height: Int): PdfRect? {
    val storedWidth = rect.optDouble("width", 0.0)
    val storedHeight = rect.optDouble("height", 0.0)
    if (page < 1 || width <= 0 || height <= 0 || storedWidth <= 0 || storedHeight <= 0) return null
    val x1 = rect.optDouble("x1") / storedWidth * width
    val y1 = rect.optDouble("y1") / storedHeight * height
    val x2 = rect.optDouble("x2") / storedWidth * width
    val y2 = rect.optDouble("y2") / storedHeight * height
    if (!listOf(x1, y1, x2, y2).all { it.isFinite() } || x1 < 0 || y1 < 0 || x2 <= x1 || y2 <= y1) return null
    return PdfRect(page - 1, x1.toFloat(), y1.toFloat(), x2.toFloat(), y2.toFloat())
}

internal fun LuiExtensionRegistry.registerPdfWorkspace(loadAsset: (suspend (String, String) -> String)?) {
    register("native-pdf-workspace",
        "lui-extension-v1|20:native-pdf-workspace|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:7:payload:string:required:none|events:5:event[7:payload:string:required]",
        acceptsStandardChildren = true,
        properties = listOf(LuiExtensionProperty("payload", LuiExtensionValueKind.STRING, required = true)),
        events = listOf(LuiExtensionEventSchema("event", listOf(LuiExtensionProperty("payload", LuiExtensionValueKind.STRING, required = true)))),
    ) { PdfWorkspace(this, loadAsset) }
}

@Composable private fun PdfWorkspace(context: LuiExtensionContext, loadAsset: (suspend (String, String) -> String)?) {
    val text = context.string("payload") ?: "null"
    val payload = remember(text) { runCatching { JSONObject(text) }.getOrNull() }
    var fraction by remember { mutableFloatStateOf(0.5f) }
    fun send(value: JSONObject) = context.emit("event", "payload" to value.toString())
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val fullScreen = payload != null && if (payload.has("fullScreen")) payload.optBoolean("fullScreen") else maxWidth < 600.dp
        val totalWidthPx = constraints.maxWidth.toFloat().coerceAtLeast(1f)
        val pdfWidth = (maxWidth.value * fraction).coerceIn(maxWidth.value * 0.2f, maxWidth.value * 0.8f).dp
        val mainWidth = if (payload == null) maxWidth else (maxWidth - pdfWidth - 14.dp).coerceAtLeast(0.dp)
        val readerWidth = if (fullScreen) maxWidth else pdfWidth
        Box(Modifier.width(mainWidth).fillMaxHeight()
            .offset(x = if (payload == null) 0.dp else readerWidth + 14.dp)
            .alpha(if (fullScreen) 0f else 1f)
            .then(if (fullScreen) Modifier.clearAndSetSemantics { } else Modifier)
            .testTag("pdf.main")) {
            CompositionLocalProvider(LocalOpenPDF provides { uuid, title, path ->
                send(JSONObject().put("action", "open").put("uuid", uuid).put("title", title).put("path", path))
            }) { context.Children() }
        }
        Box(Modifier.width(if (payload == null) 0.dp else readerWidth).fillMaxHeight()) {
            if (payload != null) key(payload.optString("graphId"), payload.optString("assetUuid")) {
                NativePdfReader(payload, loadAsset, fullScreen, ::send)
            }
        }
        if (payload != null && !fullScreen) Box(Modifier.offset(x = pdfWidth).width(14.dp).fillMaxHeight()
            .pointerInput(totalWidthPx) {
                detectHorizontalDragGestures { change, delta ->
                    change.consume()
                    fraction = (fraction + delta / totalWidthPx).coerceIn(0.2f, 0.8f)
                }
            }.testTag("pdf.divider"), contentAlignment = Alignment.Center) {
            Box(Modifier.width(2.dp).fillMaxHeight().background(MaterialTheme.colorScheme.outlineVariant))
        }
    }
}

@OptIn(ExperimentalPdfApi::class)
@Composable private fun NativePdfReader(payload: JSONObject, loadAsset: (suspend (String, String) -> String)?, fullScreen: Boolean, send: (JSONObject) -> Unit) {
    val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    LaunchedEffect(fullScreen) { if (fullScreen) { focus.clearFocus(); keyboard?.hide() } }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    val viewer = rememberPdfViewerState()
    val latestSend by rememberUpdatedState<(JSONObject) -> Unit>({ value ->
        send(value.put("graphId", payload.getString("graphId")).put("assetUuid", payload.getString("assetUuid")))
    })
    var document by remember { mutableStateOf<PdfDocument?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    var ready by remember { mutableStateOf(false) }
    var contentLoaded by remember { mutableStateOf(false) }
    var navigationToken by remember { mutableStateOf<String?>(null) }
    var color by remember { mutableStateOf("yellow") }
    var colorsOpen by remember { mutableStateOf(false) }
    var selectedID by remember { mutableStateOf<String?>(null) }
    var penSelection by remember { mutableStateOf<PageSelection?>(null) }
    var selecting by remember { mutableStateOf(false) }
    var selectionJob by remember { mutableStateOf<Job?>(null) }
    var selectionGeneration by remember { mutableIntStateOf(0) }
    val highlightText = payload.optJSONArray("highlights")?.toString() ?: "[]"
    val highlights = remember(highlightText) { val list = JSONArray(highlightText); (0 until list.length()).map { list.getJSONObject(it) } }
    val latestHighlights by rememberUpdatedState(highlights)
    val pageSizes = remember(document) { mutableMapOf<Int, PdfDocument.PageInfo>() }
    suspend fun pageInfo(doc: PdfDocument, number: Int) = pageSizes[number] ?: doc.getPageInfo(number).also { pageSizes[number] = it }

    LaunchedEffect(retry) {
        var opened: PdfDocument? = null
        try {
            error = null
            ready = false
            contentLoaded = false
            val path = payload.optString("path").takeIf { it.isNotEmpty() && File(it).isFile }
                ?: requireNotNull(loadAsset) { "PDF download is unavailable" }(payload.getString("assetUuid"), "pdf")
            val file = File(path)
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            opened = try { SandboxedPdfLoader(context, Dispatchers.IO).openDocument(Uri.fromFile(file), descriptor) }
                catch (failure: Throwable) { descriptor.close(); throw failure }
            document = opened
            awaitCancellation()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.localizedMessage ?: "Unable to open PDF" }
        finally { document = null; opened?.close() }
    }

    LaunchedEffect(document, contentLoaded, payload.optBoolean("loading"), payload.optInt("page", 1),
        payload.optInt("targetPage"), payload.optString("navigationToken")) {
        val doc = document ?: return@LaunchedEffect
        val token = payload.optString("navigationToken")
        if (contentLoaded && (!ready || navigationToken != token) && !payload.optBoolean("loading")) {
            selectionGeneration++
            selectionJob?.cancel()
            selecting = false
            penSelection = null
            viewer.clearCurrentSelection()
            viewer.scrollToPage((payload.optInt("targetPage", payload.optInt("page", 1)) - 1).coerceIn(0, doc.pageCount - 1))
            selectedID = payload.optString("targetAnnotation").takeIf { it.isNotEmpty() }
            navigationToken = token
            ready = true
        }
    }

    LaunchedEffect(document, ready, highlightText, penSelection) {
        val doc = document ?: return@LaunchedEffect
        if (!ready) return@LaunchedEffect
        try {
            val overlays = mutableListOf<Highlight>()
            for (highlight in highlights) {
                val number = highlight.optInt("page")
                if (number !in 1..doc.pageCount) continue
                val page = pageInfo(doc, number - 1)
                val position = highlight.optJSONObject("position") ?: continue
                val rects = position.optJSONArray("rects")?.takeIf { it.length() > 0 }
                    ?: position.optJSONObject("bounding")?.let { JSONArray().put(it) } ?: continue
                for (i in 0 until rects.length()) {
                    decodePdfRect(rects.getJSONObject(i), number, page.width, page.height)?.let {
                        overlays.add(Highlight(it, highlightColor(highlight.optJSONObject("properties")?.optString("color") ?: "yellow")))
                    }
                }
            }
            penSelection?.let { selected ->
                selected.selectedContents.forEach { content -> content.bounds.forEach { rect ->
                    overlays.add(Highlight(PdfRect(selected.page, rect), highlightColor("blue")))
                } }
            }
            viewer.setHighlights(overlays)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.localizedMessage }
    }

    LaunchedEffect(viewer.firstVisiblePage, ready) {
        if (ready) { delay(500); latestSend(JSONObject().put("action", "visit").put("page", viewer.firstVisiblePage + 1)) }
    }

    LaunchedEffect(viewer.currentSelection) {
        if ((viewer.currentSelection as? TextSelection)?.text?.isNotBlank() == true) {
            selectedID = null
            selectionGeneration++
            selectionJob?.cancel()
            selecting = false
            penSelection = null
        }
    }

    fun save() {
        val doc = document ?: return
        val pen = penSelection
        val selection = viewer.currentSelection as? TextSelection
        scope.launch {
            try {
                val pages: List<Pair<String, List<PdfRect>>> = if (pen != null) {
                    listOf(pen.selectedContents.filterIsInstance<PdfPageTextContent>().joinToString("\n") { it.text } to
                        pen.selectedContents.flatMap { it.bounds }.map { PdfRect(pen.page, it) })
                } else if (selection != null) {
                    selection.bounds.groupBy { it.pageNum }.map { (page, bounds) ->
                        val text = if (selection.bounds.all { it.pageNum == page }) selection.text.toString()
                            else doc.getSelectionBounds(page,
                                PointF(bounds.first().left, (bounds.first().top + bounds.first().bottom) / 2),
                                PointF(bounds.last().right, (bounds.last().top + bounds.last().bottom) / 2))
                                ?.selectedContents?.filterIsInstance<PdfPageTextContent>()?.joinToString("\n") { it.text }.orEmpty()
                        text to bounds
                    }
                } else emptyList()
                for ((text, bounds) in pages) {
                    if (text.isBlank() || bounds.isEmpty()) continue
                    val page = pageInfo(doc, bounds.first().pageNum)
                    val id = UUID.randomUUID().toString()
                    val highlight = encodePdfHighlight(id, page.pageNum + 1, page.width, page.height, text, bounds, color)
                    latestSend(JSONObject().put("action", "save").put("highlight", highlight))
                    selectedID = id
                }
                viewer.clearCurrentSelection()
                penSelection = null
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = failure.localizedMessage }
        }
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).statusBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { latestSend(JSONObject().put("action", "close")) }, modifier = Modifier.testTag("pdf.close")) {
                Icon(Icons.Filled.Close, "Close PDF")
            }
            Text(payload.optString("title"), modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
            IconButton(onClick = {
                latestSend(JSONObject().put("action", "set-fullscreen").put("fullScreen", !fullScreen))
            },
                modifier = Modifier.testTag("pdf.toggle-fullscreen")) {
                Icon(if (fullScreen) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen,
                    if (fullScreen) "Show PDF and notes" else "Full-screen PDF")
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = ::save, enabled = ready && !selecting &&
                (penSelection != null || (viewer.currentSelection as? TextSelection)?.text?.isNotBlank() == true),
                modifier = Modifier.testTag("pdf.highlight")) { Text("Highlight") }
            Box {
                TextButton(onClick = { colorsOpen = true }) { Text(color.replaceFirstChar { it.uppercase() }) }
                DropdownMenu(expanded = colorsOpen, onDismissRequest = { colorsOpen = false }) {
                    colors.forEach { choice -> DropdownMenuItem(text = { Text(choice.replaceFirstChar { it.uppercase() }) }, onClick = {
                        color = choice
                        colorsOpen = false
                        selectedID?.let { latestSend(JSONObject().put("action", "recolor").put("id", it).put("color", choice)) }
                    }) }
                }
            }
            TextButton(onClick = { latestSend(JSONObject().put("action", "open-annotations")) }) { Text("Notes") }
            TextButton(enabled = selectedID != null, onClick = { selectedID?.let { id -> scope.launch {
                clipboard.setClipEntry(android.content.ClipData.newPlainText("Annotation reference", "(($id))").toClipEntry())
            } } }) { Text("Copy reference") }
            TextButton(enabled = selectedID != null, onClick = {
                latestSend(JSONObject().put("action", "delete").put("id", selectedID)); selectedID = null
            }) { Text("Delete") }
        }
        val message = error ?: payload.optString("error").takeIf { it.isNotEmpty() && it != "null" }
        if (message != null) {
            Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            TextButton(onClick = { if (document == null) retry++; latestSend(JSONObject().put("action", "load")) }) { Text("Retry") }
        }
        Text("${viewer.firstVisiblePage + 1} / ${document?.pageCount ?: 0} · Select text to highlight", style = MaterialTheme.typography.labelSmall)
        val doc = document
        if (doc == null && error == null) CircularProgressIndicator(Modifier.padding(16.dp))
        if (doc != null) {
            Box(Modifier.weight(1f).fillMaxWidth().testTag("pdf.document")
                .semantics { stateDescription = if (ready) "PDF ready" else "Loading PDF" }.pointerInput(doc, viewer) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    val start = viewer.visibleOffsetToPdfPoint(down.position)
                    if (down.type == PointerType.Stylus && start != null && ready) {
                        down.consume()
                        selectionGeneration++
                        selectionJob?.cancel()
                        selecting = false
                        viewer.clearCurrentSelection()
                        selectedID = null
                        penSelection = null
                        var pressed = true
                        while (pressed) {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            change.consume()
                            val end = viewer.visibleOffsetToPdfPoint(change.position)
                            if (end != null && end.pageNum == start.pageNum) {
                                selectionJob?.cancel()
                                val generation = ++selectionGeneration
                                selecting = true
                                selectionJob = scope.launch {
                                    try {
                                        val selection = doc.getSelectionBounds(start.pageNum, PointF(start.x, start.y), PointF(end.x, end.y))
                                        if (generation == selectionGeneration) penSelection = selection
                                    }
                                    catch (cancelled: CancellationException) { throw cancelled }
                                    catch (failure: Exception) { error = failure.localizedMessage }
                                    finally { if (generation == selectionGeneration) selecting = false }
                                }
                            }
                            pressed = change.pressed
                        }
                    } else {
                        val initial = down.position
                        val startTime = down.uptimeMillis
                        var last = down
                        while (last.pressed) {
                            val event = awaitPointerEvent(PointerEventPass.Final)
                            last = event.changes.firstOrNull { it.id == down.id } ?: break
                        }
                        if ((last.position - initial).getDistance() < 12 && last.uptimeMillis - startTime < 300) {
                            penSelection = null
                            val point = viewer.visibleOffsetToPdfPoint(last.position)
                            if (point != null) {
                                selectedID = latestHighlights.firstOrNull { highlight ->
                                    if (highlight.optInt("page") != point.pageNum + 1) false else {
                                        val rect = highlight.optJSONObject("position")?.optJSONObject("bounding")
                                        val page = pageSizes[point.pageNum]
                                        val bounds = if (rect != null && page != null) decodePdfRect(rect, point.pageNum + 1, page.width, page.height) else null
                                        bounds != null && point.x in bounds.left..bounds.right && point.y in bounds.top..bounds.bottom
                                    }
                                }?.optString("id")
                            }
                        }
                    }
                }
            }) {
                PdfViewer(pdfDocument = doc, state = viewer, modifier = Modifier.fillMaxSize(),
                    appendContextMenuComponents = { item("logseq-highlight", "Highlight", "Highlight selected text") { save() } },
                    onFirstContentLoad = { contentLoaded = true })
            }
        }
    }
}

@Composable internal fun PdfAssetButton(uuid: String, title: String, assetType: String, localPath: String,
    loadAsset: (suspend (String, String) -> String)?) {
    val open = LocalOpenPDF.current
    val scope = rememberCoroutineScope()
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Column {
        TextButton(enabled = !loading && open != null, onClick = {
            scope.launch {
                loading = true
                error = null
                try {
                    val path = localPath.takeIf { it.isNotEmpty() && File(it).isFile }
                        ?: requireNotNull(loadAsset) { "PDF download is unavailable" }(uuid, assetType)
                    open?.invoke(uuid, title, path)
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { error = failure.localizedMessage }
                finally { loading = false }
            }
        }, modifier = Modifier.testTag("pdf.open.$uuid")) {
            Text(title.ifEmpty { "PDF" })
            if (loading) CircularProgressIndicator(Modifier.size(20.dp).padding(start = 4.dp))
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
