package com.logseq.app.ui

import android.Manifest
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.logseq.app.ui.extensions.LogseqDialogs
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ImageGallery(
    paths: List<String>,
    initialIndex: Int,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
    onShare: (String) -> Unit,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
) {
    val pager = rememberPagerState(initialPage = initialIndex.coerceIn(0, max(0, paths.lastIndex))) { paths.size }
    var zoomed by remember { mutableStateOf(false) }
    LaunchedEffect(pager.currentPage) { zoomed = false }
    val current = paths.getOrNull(pager.currentPage)
    val available = current != null && File(current).isFile
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            modifier = Modifier.fillMaxSize().semantics { testTagsAsResourceId = true },
            snackbarHost = { SnackbarHost(snackbar) },
            topBar = {
                TopAppBar(
                    title = { Text(if (paths.isEmpty()) "0 / 0" else "${pager.currentPage + 1} / ${paths.size}") },
                    navigationIcon = {
                        IconButton(onClick = onDismiss, modifier = Modifier.testTag("image.preview.close")) {
                            Icon(Icons.Default.Close, contentDescription = "Close image preview")
                        }
                    },
                    actions = {
                        TextButton(onClick = { current?.let(onSave) }, enabled = available,
                            modifier = Modifier.testTag("image.preview.save")) { Text("Save") }
                        TextButton(onClick = { current?.let(onShare) }, enabled = available,
                            modifier = Modifier.testTag("image.preview.share")) { Text("Share") }
                    },
                )
            },
        ) { padding ->
            if (paths.isEmpty()) {
                Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { Text("Image unavailable") }
            } else {
                HorizontalPager(pager, userScrollEnabled = !zoomed,
                    modifier = Modifier.fillMaxSize().padding(padding).testTag("image.preview.gallery")) { page ->
                    GalleryImage(paths[page], page) { if (page == pager.currentPage) zoomed = it }
                }
            }
        }
    }
}

@Composable
private fun GalleryImage(path: String, page: Int, onZoom: (Boolean) -> Unit) {
    val result by produceState<Result<Bitmap?>?>(null, path) {
        value = runCatching { withContext(Dispatchers.IO) {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, options)
            options.inSampleSize = 1
            while (max(options.outWidth, options.outHeight) / options.inSampleSize > 4096) options.inSampleSize *= 2
            options.inJustDecodeBounds = false
            BitmapFactory.decodeFile(path, options)
        } }
    }
    val bitmap = result?.getOrNull()
    var scale by remember(path) { mutableFloatStateOf(1f) }
    var offset by remember(path) { mutableStateOf(Offset.Zero) }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    val transform = rememberTransformableState { centroid, zoom, pan, _ ->
        val oldScale = scale
        scale = (scale * zoom).coerceIn(1f, 8f)
        val fit = if (bitmap == null) 1f else min(viewport.width.toFloat() / bitmap.width, viewport.height.toFloat() / bitmap.height)
        val maxX = max(0f, ((bitmap?.width ?: viewport.width) * fit * scale - viewport.width) / 2)
        val maxY = max(0f, ((bitmap?.height ?: viewport.height) * fit * scale - viewport.height) / 2)
        val anchor = centroid - Offset(viewport.width / 2f, viewport.height / 2f)
        val desired = (offset - anchor) * (scale / oldScale) + anchor + pan
        offset = Offset(desired.x.coerceIn(-maxX, maxX), desired.y.coerceIn(-maxY, maxY))
        onZoom(scale > 1f)
    }
    Box(Modifier.fillMaxSize().clipToBounds().onSizeChanged { viewport = it }.testTag("image.preview.zoom.$page")
        .semantics { stateDescription = "Zoom ${(scale * 100).roundToInt()}%" }
        .pointerInput(path) { detectTapGestures(onDoubleTap = {
            scale = if (scale > 1f) 1f else 2f
            offset = Offset.Zero
            onZoom(scale > 1f)
        }) }
        .transformable(transform, canPan = { scale > 1f }), contentAlignment = Alignment.Center) {
        when {
            bitmap != null -> Image(bitmap.asImageBitmap(), contentDescription = File(path).name,
                contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().graphicsLayer {
                    scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y
                })
            result == null -> CircularProgressIndicator()
            else -> Text("Image unavailable")
        }
    }
}

internal fun saveGalleryImage(context: Context, path: String): Uri {
    val file = File(path)
    require(file.isFile) { "Image unavailable" }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Not a supported image" }
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, file.name)
        put(MediaStore.Images.Media.MIME_TYPE, bounds.outMimeType ?: "image/jpeg")
        if (Build.VERSION.SDK_INT >= 29) {
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Logseq")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
    }
    val resolver = context.contentResolver
    val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
    try {
        requireNotNull(resolver.openOutputStream(uri)).use { out -> file.inputStream().use { it.copyTo(out) } }
        if (Build.VERSION.SDK_INT >= 29) resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        return uri
    } catch (failure: Throwable) {
        resolver.delete(uri, null, null)
        throw failure
    }
}

@Composable
internal fun ImageGalleryHost() {
    val request = LogseqDialogs.imageGallery ?: return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var pendingSave by remember { mutableStateOf<String?>(null) }
    val save: (String) -> Unit = { path -> scope.launch {
        try {
            withContext(Dispatchers.IO) { saveGalleryImage(context, path) }
            snackbar.showSnackbar("Saved to gallery")
        } catch (failure: Exception) { snackbar.showSnackbar("Could not save image: ${failure.message}") }
    } }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val path = pendingSave
        pendingSave = null
        if (granted && path != null) save(path)
        else scope.launch { snackbar.showSnackbar("Photo storage permission was denied") }
    }
    ImageGallery(request.paths, request.selectedIndex, { LogseqDialogs.closeImageGallery() }, onSave = { path ->
        if (Build.VERSION.SDK_INT < 29 && ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            pendingSave = path
            permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else save(path)
    }, onShare = { path ->
        try {
            val file = File(path)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "image/*"
            val share = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newUri(context.contentResolver, file.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(share, "Share image"))
        } catch (failure: Exception) { scope.launch { snackbar.showSnackbar("Could not share image: ${failure.message}") } }
    }, snackbar = snackbar)
}
