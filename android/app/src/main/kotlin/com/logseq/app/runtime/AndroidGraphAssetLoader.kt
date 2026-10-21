package com.logseq.app.runtime

import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject
import kotlin.coroutines.resumeWithException

// The core owns graph selection, authorization, decryption and final cache paths.
internal class AndroidGraphAssetLoader(
    private val directory: File,
    private val callCore: suspend (String) -> String,
) {
    private val client = OkHttpClient()

    suspend fun load(uuid: String, assetType: String): String {
        val metadata = JSONObject().put("uuid", uuid).put("assetType", assetType)
        val prepared = call("prepareAssetDownload", metadata)
        prepared.optString("localPath").takeIf(String::isNotEmpty)?.let { return it }
        val pending = prepared.getJSONObject("request")
        val file = download(Request.Builder().url(pending.getString("url"))
            .header("Authorization", "Bearer " + pending.optString("token")).build())
        try {
            return withContext(Dispatchers.IO) {
                ensureActive()
                call("cacheDownloadedAsset", metadata.put("graphId", prepared.getString("graphId"))
                    .put("path", file.path)).getString("localPath")
            }
        } finally { file.delete() }
    }

    private suspend fun call(action: String, metadata: JSONObject): JSONObject {
        val response = JSONObject(callCore(JSONObject().put("apiVersion", 1).put("method", "dispatch")
            .put("params", JSONObject().put("action", action).put("payload", metadata.toString())).toString()))
        check(response.optBoolean("ok")) {
            response.optJSONObject("error")?.optString("message") ?: "Image download failed"
        }
        return response.getJSONObject("result")
    }

    private suspend fun download(request: Request): File = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                continuation.resumeWithException(error)
            }
            override fun onResponse(call: Call, response: Response) {
                var temporary: File? = null
                try {
                    response.use {
                        check(it.code == 200) { "Image download failed (HTTP ${it.code})" }
                        directory.mkdirs()
                        val file = File.createTempFile("asset-", ".download", directory)
                        temporary = file
                        requireNotNull(it.body).byteStream().use { input ->
                            file.outputStream().use { output -> input.copyTo(output) }
                        }
                        continuation.resume(file) { _, abandoned, _ -> abandoned.delete() }
                        temporary = null
                    }
                } catch (error: Throwable) {
                    temporary?.delete()
                    continuation.resumeWithException(error)
                }
            }
        })
    }
}
