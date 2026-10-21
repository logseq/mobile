package com.logseq.app.runtime

import java.util.ArrayDeque
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject

// Kotlin port of the former android_app_entry.dart +
// android_imported_asset.dart: intents arriving on MainActivity are
// normalized into entries (deep link, shared text, shared asset) and fed
// to the core once bootstrap finishes.
internal enum class AndroidAppEntryKind { OpenCapture, OpenJournal, SharedText, SharedAsset, DeepLink }

internal data class AndroidImportedAsset(
    val uuid: String,
    val title: String,
    val assetType: String,
    val size: Long,
    val checksum: String,
    val localPath: String,
) {
    fun coreRequest(targetBlockId: String? = null): String {
        val payload = JSONObject()
            .put("uuid", uuid)
            .put("title", title)
            .put("assetType", assetType)
            .put("assetSize", size)
            .put("assetChecksum", checksum)
            .put("localPath", localPath)
        if (!targetBlockId.isNullOrEmpty()) payload.put("targetBlockId", targetBlockId)
        return JSONObject()
            .put("apiVersion", 1)
            .put("method", "dispatch")
            .put(
                "params",
                JSONObject()
                    .put("action", "addAsset")
                    .put("payload", payload.toString()),
            )
            .toString()
    }

    companion object {
        fun fromMap(value: Map<String, Any?>): AndroidImportedAsset {
            fun requiredString(key: String): String =
                (value[key] as? String)?.takeIf(String::isNotEmpty)
                    ?: throw IllegalArgumentException("Imported asset is missing $key")
            val size = (value["size"] as? Number)?.toLong()
                ?: throw IllegalArgumentException("Imported asset has an invalid size")
            require(size > 0) { "Imported asset has an invalid size" }
            return AndroidImportedAsset(
                uuid = requiredString("uuid"),
                title = requiredString("title"),
                assetType = requiredString("assetType"),
                size = size,
                checksum = requiredString("checksum"),
                localPath = requiredString("localPath"),
            )
        }
    }
}

internal data class AndroidAppEntry(
    val kind: AndroidAppEntryKind,
    val text: String? = null,
    val title: String? = null,
    val deepLink: Map<String, Any?>? = null,
    val captureUuid: String = java.util.UUID.randomUUID().toString(),
    val asset: AndroidImportedAsset? = null,
) {
    fun coreRequest(): String {
        val payload = if (kind == AndroidAppEntryKind.DeepLink) JSONObject(requireNotNull(deepLink))
            else JSONObject().put("text", text).put("title", title)
        payload.put("uuid", captureUuid)
        val action = if (kind == AndroidAppEntryKind.DeepLink) "handleDeepLink" else "captureShared"
        return JSONObject().put("apiVersion", 1).put("method", "dispatch")
            .put("params", JSONObject().put("action", action).put("payload", payload.toString())).toString()
    }

    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(value: Map<String, Any?>): AndroidAppEntry = (when (value["kind"]) {
            "open-capture" -> AndroidAppEntry(kind = AndroidAppEntryKind.OpenCapture)
            "open-journal" -> AndroidAppEntry(kind = AndroidAppEntryKind.OpenJournal)
            "shared-text" -> {
                val text = value["text"] as? String
                val title = value["title"] as? String
                require(!text.isNullOrBlank() || !title.isNullOrBlank()) { "A shared-text entry needs content" }
                AndroidAppEntry(kind = AndroidAppEntryKind.SharedText, text = text, title = title)
            }
            "deep-link" -> AndroidAppEntry(kind = AndroidAppEntryKind.DeepLink, deepLink = value)
            "shared-asset" -> {
                val asset = value["asset"] as? Map<String, Any?>
                    ?: throw IllegalArgumentException("A shared-asset entry needs an asset")
                AndroidAppEntry(
                    kind = AndroidAppEntryKind.SharedAsset,
                    asset = AndroidImportedAsset.fromMap(asset),
                )
            }
            else -> throw IllegalArgumentException(
                "Unsupported Android app entry: ${value["kind"]}"
            )
        }).let { entry ->
            val id = value["captureUuid"] as? String
            if (id == null) entry else entry.copy(captureUuid = java.util.UUID.fromString(id).toString())
        }
    }
}

// Persist before delivery; only a successful graph operation acknowledges an entry.
internal class AndroidAppEntryCoordinator(
    private val scope: CoroutineScope,
    private val handle: suspend (AndroidAppEntry) -> Unit,
    private val onError: (Throwable) -> Unit = {},
    directory: File,
) {
    private val store = AndroidAppEntryStore(directory)
    private val pending = ArrayDeque<AndroidAppEntry>()
    private val mutex = Mutex()
    private var loaded = false
    private var ready = false
    private var drainJob: Job? = null

    private suspend fun load() {
        if (!loaded) {
            pending.addAll(withContext(Dispatchers.IO) { store.pending(onError) })
            loaded = true
        }
    }

    suspend fun publish(value: Map<String, Any?>) {
        val entry = AndroidAppEntry.fromMap(value)
        mutex.withLock {
            load()
            if (pending.none { it.captureUuid == entry.captureUuid }) {
                val saved = withContext(Dispatchers.IO) { store.save(entry) }
                pending.addLast(saved)
            }
        }
        if (ready) scheduleDrain()
    }

    fun markReady() {
        ready = true
        scheduleDrain()
    }

    private fun scheduleDrain() {
        if (drainJob?.isActive == true) return
        drainJob = scope.launch {
            while (ready) {
                val entry = mutex.withLock { load(); pending.peekFirst() } ?: break
                try {
                    handle(entry)
                    mutex.withLock {
                        withContext(Dispatchers.IO) { store.acknowledge(entry) }
                        pending.removeFirst()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    onError(error)
                    break
                }
            }
        }
    }
}

private class AndroidAppEntryStore(private val directory: File) {
    private var lastOrder = System.currentTimeMillis()

    fun save(entry: AndroidAppEntry): AndroidAppEntry {
        val folder = File(directory, entry.captureUuid).apply { check(isDirectory || mkdirs()) }
        val metadata = File(folder, "entry.json")
        if (metadata.isFile) return decode(JSONObject(metadata.readText()))
        val saved = entry.asset?.let { asset ->
            val destination = File(folder, "attachment")
            java.io.FileOutputStream(destination).use { output ->
                File(asset.localPath).inputStream().use { it.copyTo(output) }
                output.fd.sync()
            }
            entry.copy(asset = asset.copy(localPath = destination.path))
        } ?: entry
        val json = JSONObject().put("kind", saved.kind.name).put("captureUuid", saved.captureUuid)
            .put("text", saved.text).put("title", saved.title)
            .put("deepLink", saved.deepLink?.let { JSONObject(it) })
            .put("order", maxOf(System.currentTimeMillis(), lastOrder + 1).also { lastOrder = it })
        saved.asset?.let { asset -> json.put("asset", JSONObject().put("uuid", asset.uuid)
            .put("title", asset.title).put("assetType", asset.assetType).put("size", asset.size)
            .put("checksum", asset.checksum).put("localPath", asset.localPath)) }
        val temporary = File(folder, "entry.tmp")
        java.io.FileOutputStream(temporary).use { output ->
            output.write(json.toString().toByteArray(Charsets.UTF_8)); output.fd.sync()
        }
        java.nio.file.Files.move(temporary.toPath(), metadata.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE)
        return saved
    }

    fun pending(onError: (Throwable) -> Unit): List<AndroidAppEntry> = directory.listFiles().orEmpty()
        .mapNotNull { folder ->
            val metadata = File(folder, "entry.json")
            if (!metadata.isFile) null else try {
                val json = JSONObject(metadata.readText())
                json.getLong("order") to decode(json)
            } catch (error: Exception) { onError(error); null }
        }.sortedBy { it.first }.map { it.second }

    fun acknowledge(entry: AndroidAppEntry) {
        val folder = File(directory, entry.captureUuid)
        // Remove the durable entry before its staged bytes: interrupted cleanup cannot replay it.
        val metadata = File(folder, "entry.json")
        check(!metadata.exists() || metadata.delete()) { "Could not acknowledge incoming share" }
        folder.deleteRecursively()
    }

    private fun decode(json: JSONObject): AndroidAppEntry {
        fun map(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
            value.opt(key).let { if (it == JSONObject.NULL) null else it }
        }
        return AndroidAppEntry(
            kind = AndroidAppEntryKind.valueOf(json.getString("kind")),
            text = json.opt("text") as? String, title = json.opt("title") as? String,
            deepLink = json.optJSONObject("deepLink")?.let(::map),
            captureUuid = java.util.UUID.fromString(json.getString("captureUuid")).toString(),
            asset = json.optJSONObject("asset")?.let { AndroidImportedAsset.fromMap(map(it)) },
        )
    }
}
