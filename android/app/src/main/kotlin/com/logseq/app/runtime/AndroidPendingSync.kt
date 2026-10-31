package com.logseq.app.runtime

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

// Kotlin port of PendingSyncTransport.swift: the core emits
// `pendingSyncRequest` objects on every snapshot while a pending-sync pump
// is active; the host performs the HTTP request and reports back through
// the `completePendingSync` dispatch action.

internal data class AndroidPendingSyncRequest(
    val id: Long,
    val method: String,
    val url: String,
    val body: String?,
    val token: String,
    val filePath: String?,
    val contentType: String,
    val headers: Map<String, String>,
    val delayMs: Long = 0,
) {
    companion object {
        fun fromJson(json: JSONObject): AndroidPendingSyncRequest {
            val headers = mutableMapOf<String, String>()
            json.optJSONObject("headers")?.let { obj ->
                for (key in obj.keys()) headers[key] = obj.getString(key)
            }
            return AndroidPendingSyncRequest(
                id = json.getLong("id"),
                method = json.getString("method"),
                url = json.getString("url"),
                body = json.optString("body").takeUnless { it.isEmpty() || json.isNull("body") },
                token = json.getString("token"),
                filePath = json.optString("filePath").takeUnless { it.isEmpty() || json.isNull("filePath") },
                contentType = json.getString("contentType"),
                headers = headers,
                delayMs = json.optLong("delayMs", 0),
            )
        }
    }
}

internal data class AndroidPendingSyncResult(
    val status: Int?,
    val body: String?,
    val error: String?,
)

internal object AndroidPendingSyncTransport {

    fun send(pending: AndroidPendingSyncRequest): AndroidPendingSyncResult = try {
        val uploadFile = pending.filePath?.let { path ->
            val file = File(path)
            if (!file.isFile) {
                return AndroidPendingSyncResult(null, null, "Pending sync asset file does not exist: $path")
            }
            file
        }
        val connection = openConnection(pending.url)
        try {
            connection.requestMethod = pending.method
            connection.setRequestProperty("Authorization", "Bearer ${pending.token}")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Content-Type", pending.contentType)
            for ((name, value) in pending.headers) {
                connection.setRequestProperty(name, value)
            }
            when {
                uploadFile != null -> {
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(uploadFile.length())
                    uploadFile.inputStream().use { input ->
                        connection.outputStream.use { output -> input.copyTo(output) }
                    }
                }
                pending.body != null -> {
                    connection.doOutput = true
                    connection.outputStream.use { it.write(pending.body.toByteArray(Charsets.UTF_8)) }
                }
            }
            val status = connection.responseCode
            val body = readBody(connection)
            AndroidPendingSyncResult(status, body, null)
        } finally {
            connection.disconnect()
        }
    } catch (error: Throwable) {
        AndroidPendingSyncResult(null, null, error.toString())
    }

    private fun openConnection(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 30_000
        }

    private fun readBody(connection: HttpURLConnection): String {
        val stream = runCatching { connection.inputStream }
            .getOrNull() ?: connection.errorStream ?: return ""
        return stream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

}

// Drives the pump loop: beginPendingSync -> request -> transport ->
// completePendingSync, mirroring ViewModel.runPendingSyncPump.
internal class AndroidPendingSyncPump(
    private val callCore: suspend (String) -> String,
    private val applyResponse: suspend (String) -> Unit,
    private val isCancelled: () -> Boolean,
    private val log: (String, String) -> Unit = { _, _ -> },
    private val accessTokenProvider: (suspend () -> String?)? = null,
) {
    suspend fun run() {
        val beginResponse = callCore(dispatchRequest("beginPendingSync"))
        applyResponse(beginResponse)
        var pending = pendingRequestFrom(beginResponse)
        try {
            while (pending != null && !isCancelled()) {
                if (pending.delayMs > 0) kotlinx.coroutines.delay(pending.delayMs)
                if (isCancelled()) break
                val authorized = if (accessTokenProvider != null) {
                    val token = try {
                        accessTokenProvider.invoke()
                    } catch (error: kotlinx.coroutines.CancellationException) {
                        throw error
                    } catch (_: Exception) { null }
                    if (token.isNullOrBlank()) {
                        applyResponse(callCore(dispatchRequest("cancelPendingSync")))
                        return
                    }
                    pending.copy(token = token)
                } else pending
                if (isCancelled()) break
                val result = withContext(Dispatchers.IO) {
                    AndroidPendingSyncTransport.send(authorized)
                }
                if (isCancelled()) break
                val completion = JSONObject()
                    .put("id", pending.id)
                    .put("status", result.status?.let { JSONObject.wrap(it) } ?: JSONObject.NULL)
                    .put("body", result.body ?: JSONObject.NULL)
                    .put("error", result.error ?: JSONObject.NULL)
                val completionResponse = callCore(
                    dispatchRequest("completePendingSync", completion.toString())
                )
                applyResponse(completionResponse)
                if (result.error == null && result.status !in 200..299) {
                    log(
                        "error",
                        "Pending sync HTTP ${result.status}: ${result.body?.take(200)}",
                    )
                }
                pending = pendingRequestFrom(completionResponse)
            }
        } finally {
            if (isCancelled()) {
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                    applyResponse(callCore(dispatchRequest("cancelPendingSync")))
                }
            }
        }
    }

    private fun dispatchRequest(action: String, payload: String? = null): String =
        JSONObject()
            .put("apiVersion", 1)
            .put("method", "dispatch")
            .put(
                "params",
                JSONObject()
                    .put("action", action)
                    .put("payload", payload ?: JSONObject.NULL),
            )
            .toString()

    private fun pendingRequestFrom(response: String): AndroidPendingSyncRequest? {
        val request = runCatching {
            JSONObject(response)
                .optJSONObject("result")
                ?.optJSONObject("pendingSyncRequest")
        }.getOrNull() ?: return null
        return runCatching { AndroidPendingSyncRequest.fromJson(request) }
            .onFailure { log("error", "Pending sync request decode failed: $it") }
            .getOrNull()
    }
}
