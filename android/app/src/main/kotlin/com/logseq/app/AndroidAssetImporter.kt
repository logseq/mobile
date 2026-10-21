package com.logseq.app

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import logseq.app.AndroidRuntimeLogLevel
import logseq.app.AndroidRuntimeLogSource
import logseq.app.AndroidRuntimeLogs

internal fun safeAssetTitle(value: String?): String =
    File(value.orEmpty()).name.trim().ifBlank { "Attachment" }

class AndroidAssetImporter(
    private val activity: Activity,
    private val scope: CoroutineScope,
) {
    private var pending: CompletableDeferred<List<Map<String, Any>>>? = null
    private var pendingCameraFile: File? = null

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == documentsRequestCode) {
            val uris = if (resultCode == Activity.RESULT_OK) data.documentUris() else emptyList()
            logInfo("Picker returned ${uris.size} item(s)")
            scope.launch {
                complete(uris.mapNotNull { uri -> importDocument(uri) })
            }
            return true
        }
        if (requestCode != cameraRequestCode) return false
        val succeeded = resultCode == Activity.RESULT_OK
        val file = pendingCameraFile
        pendingCameraFile = null
        logInfo("Camera returned succeeded=$succeeded")
        scope.launch {
            val asset = if (succeeded && file != null) {
                withContext(Dispatchers.IO) {
                    runCatching {
                        importedFile(
                            file = file,
                            title = "Camera.jpg",
                            contentType = "image/jpeg",
                        )
                    }.onFailure { error ->
                        logError("Camera import failed", error)
                        file.delete()
                    }.getOrNull()
                }
            } else {
                file?.delete()
                null
            }
            complete(listOfNotNull(asset))
        }
        return true
    }

    suspend fun import(kind: String): List<Map<String, Any>> {
        check(pending == null) { "An attachment picker is already active" }
        val result = CompletableDeferred<List<Map<String, Any>>>()
        pending = result
        logInfo("Launching picker kind=$kind")
        try {
            when (kind) {
                "camera" -> launchCamera()
                "photos" -> launchDocuments("image/*")
                "audio" -> launchDocuments("audio/*")
                "files" -> launchDocuments("*/*")
                else -> error("Unsupported attachment kind: $kind")
            }
        } catch (error: Throwable) {
            pending = null
            pendingCameraFile?.delete()
            pendingCameraFile = null
            logError("Could not launch picker kind=$kind", error)
            throw error
        }
        return result.await()
    }

    suspend fun importShared(uri: Uri): Map<String, Any>? = importDocument(uri)

    private fun launchCamera() {
        val directory = File(activity.cacheDir, assetsDirectory).apply { mkdirs() }
        val file = File(directory, "${UUID.randomUUID()}-Camera.jpg")
        pendingCameraFile = file
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            file,
        )
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            clipData = ClipData.newUri(activity.contentResolver, "Camera photo", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, cameraRequestCode)
    }

    private fun launchDocuments(contentType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = contentType
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        activity.startActivityForResult(intent, documentsRequestCode)
    }

    private suspend fun importDocument(uri: Uri): Map<String, Any>? =
        withContext(Dispatchers.IO) {
            runCatching {
                val title = displayName(uri)
                val uuid = UUID.randomUUID().toString()
                val directory = File(activity.cacheDir, assetsDirectory).apply { mkdirs() }
                val destination = File(directory, "$uuid-$title")
                activity.contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Could not open selected asset" }
                    destination.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                importedFile(
                    uuid = uuid,
                    file = destination,
                    title = title,
                    contentType = runCatching {
                        activity.contentResolver.getType(uri)
                    }.getOrNull() ?: mimeTypeFor(destination),
                )
            }.onFailure { error ->
                logError("Document import failed", error)
            }.getOrNull()
        }

    private fun importedFile(
        file: File,
        title: String,
        contentType: String,
        uuid: String = UUID.randomUUID().toString(),
    ): Map<String, Any> {
        require(file.isFile && file.length() > 0) { "Imported asset is empty" }
        val prepared = AndroidImageCompression.prepare(file, title, contentType)
        val stored = prepared.file
        val digest = MessageDigest.getInstance("SHA-256")
        stored.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val result = importedAsset(
            uuid = uuid,
            file = stored,
            title = prepared.title,
            contentType = prepared.contentType,
            size = stored.length(),
            checksum = digest.digest().toHex(),
        )
        if (stored != file) file.delete()
        return result
    }

    private fun importedAsset(
        uuid: String,
        file: File,
        title: String,
        contentType: String,
        size: Long,
        checksum: String,
    ): Map<String, Any> = mapOf(
        "uuid" to uuid,
        "title" to title,
        "assetType" to contentType,
        "size" to size.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
        "checksum" to checksum,
        "localPath" to file.path,
    )

    private fun displayName(uri: Uri): String {
        runCatching {
            activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )
        }.getOrNull()?.use { cursor ->
            if (cursor.moveToFirst()) {
                return safeAssetTitle(cursor.getString(0))
            }
        }
        return safeAssetTitle(uri.lastPathSegment)
    }

    private fun mimeTypeFor(file: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"

    private fun complete(assets: List<Map<String, Any>>) {
        val request = pending ?: return
        pending = null
        logInfo("Import complete count=${assets.size}")
        request.complete(assets)
    }

    private fun logInfo(message: String) {
        Log.i(logTag, message)
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.INFO,
            AndroidRuntimeLogSource.UI,
            message,
        )
    }

    private fun logError(message: String, error: Throwable) {
        Log.e(logTag, message, error)
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.ERROR,
            AndroidRuntimeLogSource.UI,
            "$message: ${error.message ?: error.javaClass.simpleName}",
        )
    }

    private fun ByteArray.toHex(): String = joinToString("") { byte -> "%02x".format(byte) }

    private fun Intent?.documentUris(): List<Uri> {
        if (this == null) return emptyList()
        val values = buildList {
            data?.let(::add)
            val selected = clipData
            if (selected != null) {
                for (index in 0 until selected.itemCount) {
                    selected.getItemAt(index).uri?.let(::add)
                }
            }
        }
        return values.distinct()
    }

    private companion object {
        const val logTag = "LogseqAttachment"
        const val assetsDirectory = "Assets"
        const val documentsRequestCode = 4201
        const val cameraRequestCode = 4202
    }
}
