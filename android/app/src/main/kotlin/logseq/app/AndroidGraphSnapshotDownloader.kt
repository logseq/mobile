package logseq.app

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.zip.GZIPInputStream
import org.json.JSONObject

data class AndroidDownloadedGraphSnapshot(
    val metadataBody: String,
    val filePath: String,
)

class AndroidGraphSnapshotException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

class AndroidGraphSnapshotDownloader {
    suspend fun download(
        baseUrl: String,
        graphId: String,
        accessToken: String,
        workingDirectory: String,
        callCore: suspend (String) -> String,
    ): AndroidDownloadedGraphSnapshot {
        val plan = shared(callCore, "snapshotDownloadPlan", JSONObject().put("baseUrl", baseUrl).put("graphId", graphId))
        val metadataUrl = URL(plan.getString("metadataURL"))
        val metadataBody = readText(metadataUrl, accessToken, "Snapshot metadata")
        val resolved = shared(callCore, "resolveSnapshotDownload", JSONObject()
            .put("metadataBody", metadataBody))
        val snapshotUrl = URL(metadataUrl, resolved.getString("downloadURL"))

        val directory = File(workingDirectory)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw AndroidGraphSnapshotException(
                "Could not create snapshot directory: ${directory.absolutePath}",
            )
        }
        val download = File.createTempFile("logseq-graph-", ".download", directory)
        var decoded: File? = null
        try {
            downloadFile(snapshotUrl, accessToken, download)
            val hasGzipLayer = download.inputStream().use { it.read() == 0x1f && it.read() == 0x8b }
            val snapshot = if (hasGzipLayer) {
                File.createTempFile("logseq-graph-", ".snapshot", directory).also { output ->
                    decoded = output
                    GZIPInputStream(download.inputStream().buffered()).use { input ->
                        output.outputStream().buffered().use(input::copyTo)
                    }
                    if (!download.delete()) {
                        throw AndroidGraphSnapshotException(
                            "Could not remove compressed snapshot artifact",
                        )
                    }
                }
            } else {
                download
            }
            return AndroidDownloadedGraphSnapshot(resolved.getString("metadataBody"), snapshot.absolutePath)
        } catch (error: Exception) {
            download.delete()
            decoded?.delete()
            if (error is AndroidGraphSnapshotException) throw error
            throw AndroidGraphSnapshotException("Could not download graph snapshot", error)
        }
    }

    private suspend fun shared(callCore: suspend (String) -> String, action: String, fields: JSONObject): JSONObject {
        val response = JSONObject(callCore(JSONObject().put("apiVersion", 1).put("method", "dispatch")
            .put("params", JSONObject().put("action", action).put("payload", fields.toString())).toString()))
        if (!response.optBoolean("ok")) throw AndroidGraphSnapshotException(
            response.optJSONObject("error")?.optString("message") ?: "The shared core rejected the snapshot download")
        return response.getJSONObject("result")
    }

    private fun readText(url: URL, accessToken: String, operation: String): String {
        val connection = open(url, accessToken)
        try {
            requireSuccess(connection, operation)
            return connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun downloadFile(url: URL, accessToken: String, destination: File) {
        val connection = open(url, accessToken)
        try {
            requireSuccess(connection, "Snapshot download")
            connection.inputStream.buffered().use { input ->
                destination.outputStream().buffered().use(input::copyTo)
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: URL, accessToken: String): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 120_000
            setRequestProperty("Authorization", "Bearer $accessToken")
        }

    private fun requireSuccess(connection: HttpURLConnection, operation: String) {
        val status = connection.responseCode
        if (status !in 200..299) {
            throw AndroidGraphSnapshotException("$operation failed with HTTP $status")
        }
    }
}
