package com.logseq.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import logseq.app.AndroidGraphSnapshotDownloader
import logseq.app.AndroidRuntimeLogLevel
import logseq.app.AndroidRuntimeLogSource
import logseq.app.AndroidRuntimeLogs
import logseq.app.resolveAndroidFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

internal const val DEFAULT_BASE_URL = "https://api.logseq.io"

internal fun normalizedBaseUrl(value: String?): String =
    value?.trim().orEmpty().ifBlank { DEFAULT_BASE_URL }

internal fun resolveAppFile(filesDirectory: File, path: String): File {
    return resolveAndroidFile(filesDirectory, path)
}

class AndroidPlatformServices(private val context: Context) {
    private val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    private val snapshotDownloader = AndroidGraphSnapshotDownloader()

    fun loadStorageState(): Map<String, Any> {
        val graphsDirectory = File(context.filesDir, "graphs").apply { mkdirs() }
        val localGraphIds = AndroidGraphLocalStorage.localGraphIds(graphsDirectory)
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val rawTabs = preferences.getString("logseq.mobile.sidebarTabs", "").orEmpty()
        val baseUrl = normalizedBaseUrl(preferences.getString("logseq.baseURL", null))
        return mapOf(
            "databasePath" to File(context.filesDir, "logseq.sqlite").path,
            "graphsDirectory" to graphsDirectory.path,
            "baseUrl" to baseUrl,
            "selectedGraphId" to preferences.getString("logseq.selectedGraphId", "").orEmpty(),
            "localGraphIds" to localGraphIds,
            "composerDraft" to preferences.getString("logseq.composerDraft", "").orEmpty(),
            "settings" to mapOf(
                "appearance" to preferences.getString("logseq.appearance", "system").orEmpty(),
                "language" to preferences.getString("logseq.language", "system").orEmpty(),
                "spellCheck" to preferences.getBoolean("logseq.editor.spellCheck", true),
                "autoCorrection" to preferences.getBoolean(
                    "logseq.editor.autoCorrection",
                    true,
                ),
                "sidebarTabs" to rawTabs
                    .split(',')
                    .map(String::trim)
                    .filter(String::isNotEmpty),
                "baseURL" to baseUrl,
                "version" to packageInfo.versionName.orEmpty().ifBlank { "Development" },
                "revision" to BuildConfig.GIT_REVISION,
            ),
        )
    }

    fun persistComposerDraft(draft: String) {
        preferences.edit().putString("logseq.composerDraft", draft).apply()
    }

    fun saveSettings(encoded: String) {
        val settings = JSONObject(encoded)
        preferences.edit()
            .putString("logseq.appearance", settings.optString("appearance", "system"))
            .putString("logseq.language", settings.optString("language", "system"))
            .putBoolean("logseq.editor.spellCheck", settings.optBoolean("spellCheck", true))
            .putBoolean(
                "logseq.editor.autoCorrection",
                settings.optBoolean("autoCorrection", true),
            )
            .putString(
                "logseq.mobile.sidebarTabs",
                settings.optJSONArray("sidebarTabs")?.toStringList()?.joinToString(",")
                    ?: "journals,flashcards,graphs",
            )
            .putString(
                "logseq.baseURL",
                normalizedBaseUrl(settings.optString("baseURL", DEFAULT_BASE_URL)),
            )
            .apply()
    }

    fun openExternalUrl(url: String): Boolean {
        val parsed = Uri.parse(url)
        if (parsed.scheme !in setOf("http", "https") || parsed.host.isNullOrBlank()) return false
        return start(Intent(Intent.ACTION_VIEW, parsed))
    }

    fun copyText(text: String) {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText("Logseq", text))
    }

    fun refreshRuntimeLog(source: String, flags: Int): String {
        val requestedSource = AndroidRuntimeLogSource.entries.firstOrNull {
            it.wireValue == source
        } ?: return "[]"
        return AndroidRuntimeLogs.shared.encodedRecords(
            source = requestedSource,
            errorsOnly = flags and 1 != 0,
            newestFirst = flags and 2 != 0,
        )
    }

    fun appendRuntimeLog(level: String, source: String, message: String): Boolean {
        val requestedLevel = AndroidRuntimeLogLevel.entries.firstOrNull {
            it.wireValue.equals(level, ignoreCase = true)
        } ?: return false
        val requestedSource = AndroidRuntimeLogSource.entries.firstOrNull {
            it.wireValue == source
        } ?: return false
        AndroidRuntimeLogs.shared.append(requestedLevel, requestedSource, message)
        return true
    }

    fun presentAttachment(kind: String): Boolean {
        val intent = when (kind) {
            "camera" -> Intent(MediaStore.ACTION_IMAGE_CAPTURE)
            "photos" -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
            }
            "audio" -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "audio/*"
            }
            "files" -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }
            else -> return false
        }
        return start(intent)
    }

    fun presentAsset(metadata: String): Boolean {
        val asset = JSONObject(metadata)
        val path = asset.optString("localPath")
        if (path.isBlank()) return false
        val file = File(resolveAssetPath(path))
        if (!file.isFile) return false
        val contentType = asset.optString("assetType", "application/octet-stream")
            .ifBlank { "application/octet-stream" }
        return start(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(contentUri(file), contentType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    fun presentPageShare(text: String, metadata: String): Boolean {
        val paths = JSONArray(metadata).toStringList()
        val files = paths
            .map { path -> File(resolveAssetPath(path)) }
            .filter(File::isFile)
        val intent = if (files.size > 1) {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                putParcelableArrayListExtra(
                    Intent.EXTRA_STREAM,
                    ArrayList(files.map(::contentUri)),
                )
            }
        } else {
            Intent(Intent.ACTION_SEND).apply {
                files.firstOrNull()?.let { putExtra(Intent.EXTRA_STREAM, contentUri(it)) }
            }
        }.apply {
            type = if (files.isEmpty()) "text/plain" else "application/octet-stream"
            putExtra(Intent.EXTRA_TEXT, text)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return start(Intent.createChooser(intent, "Share from Logseq"))
    }

    fun deleteLocalGraph(graphId: String): Boolean {
        if (graphId.isBlank() || graphId.contains('/') || graphId.contains("..")) return false
        val directory = AndroidGraphLocalStorage.directory(File(context.filesDir, "graphs"), graphId)
        if (!directory.exists()) return true
        return directory.deleteRecursively()
    }

    fun exportGraphDatabase(): Boolean {
        val graphId = preferences.getString("logseq.selectedGraphId", "").orEmpty()
        if (graphId.isBlank()) return false
        val database = File(AndroidGraphLocalStorage.directory(File(context.filesDir, "graphs"), graphId), "graph.sqlite")
        if (!database.isFile) return false
        return presentPageShare("", JSONArray(listOf(database.path)).toString())
    }

    suspend fun downloadGraphSnapshot(
        baseUrl: String,
        graphId: String,
        accessToken: String,
        workingDirectory: String,
        callCore: suspend (String) -> String,
    ): Map<String, String> = withContext(Dispatchers.IO) {
        val snapshot = snapshotDownloader.download(
            baseUrl = baseUrl,
            graphId = graphId,
            accessToken = accessToken,
            workingDirectory = workingDirectory,
            callCore = callCore,
        )
        mapOf(
            "metadataBody" to snapshot.metadataBody,
            "filePath" to snapshot.filePath,
        )
    }

    fun persistSelectedGraphId(graphId: String) {
        preferences.edit().putString("logseq.selectedGraphId", graphId).apply()
    }

    // Asset paths the core emits are files-directory-relative; absolute
    // paths pass through untouched.
    fun resolveAssetPath(path: String): String =
        if (path.isEmpty() || File(path).isAbsolute) {
            path
        } else {
            val graphId = preferences.getString("logseq.selectedGraphId", "").orEmpty()
            val directory = AndroidGraphLocalStorage.directory(File(context.filesDir, "graphs"), graphId)
            val graphFile = File(directory, path)
            if (graphId.isNotBlank() && graphFile.isFile) graphFile.path
            else resolveAppFile(context.filesDir, path).path
        }

    fun deleteTemporaryFile(path: String) {
        val graphsDirectory = File(context.filesDir, "graphs").canonicalFile
        val file = File(path).canonicalFile
        val isGraphTemporaryFile = file.path.startsWith(graphsDirectory.path + File.separator) &&
            file.name.startsWith("logseq-graph-") &&
            file.extension in setOf("download", "snapshot")
        if (isGraphTemporaryFile) file.delete()
    }

    private fun contentUri(file: File): Uri = FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileprovider",
        file,
    )

    private fun start(intent: Intent): Boolean = runCatching {
        context.startActivity(intent)
        true
    }.getOrDefault(false)

    private fun JSONArray.toStringList(): List<String> =
        (0 until length()).mapNotNull { index -> optString(index).takeIf(String::isNotBlank) }

    private companion object {
        const val preferencesName = "logseq"
    }
}
