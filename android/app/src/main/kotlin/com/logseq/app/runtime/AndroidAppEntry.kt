package com.logseq.app.runtime

import java.util.ArrayDeque
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
        fun fromMap(value: Map<String, Any?>): AndroidAppEntry = when (value["kind"]) {
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
        }
    }
}

// Queued delivery: entries publish before the core is ready wait in
// `pending`; handlers run sequentially in publish order.
internal class AndroidAppEntryCoordinator(
    private val scope: CoroutineScope,
    private val handle: suspend (AndroidAppEntry) -> Unit,
    private val onError: (Throwable) -> Unit = {},
) {
    private val pending = ArrayDeque<AndroidAppEntry>()
    private var ready = false
    private var drainJob: Job? = null

    fun publish(value: Map<String, Any?>) {
        try {
            pending.addLast(AndroidAppEntry.fromMap(value))
            if (ready) scheduleDrain()
        } catch (error: Throwable) {
            onError(error)
        }
    }

    fun markReady() {
        ready = true
        scheduleDrain()
    }

    private fun scheduleDrain() {
        if (drainJob?.isActive == true) return
        drainJob = scope.launch {
            while (ready && pending.isNotEmpty()) {
                val entry = pending.removeFirst()
                try {
                    handle(entry)
                } catch (error: Throwable) {
                    pending.addFirst(entry)
                    onError(error)
                    break
                }
            }
        }
    }
}
