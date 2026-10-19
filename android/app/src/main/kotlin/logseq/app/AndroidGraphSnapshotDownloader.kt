package logseq.app

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
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
    fun download(
        baseUrl: String,
        graphId: String,
        accessToken: String,
        workingDirectory: String,
    ): AndroidDownloadedGraphSnapshot {
        val metadataUrl = snapshotMetadataUrl(baseUrl, graphId)
        val cursor = JSONObject(
            readText(snapshotCursorUrl(baseUrl, graphId), accessToken, "Snapshot cursor"),
        )
        val metadataBody = readText(metadataUrl, accessToken, "Snapshot metadata")
        val metadata = runCatching { JSONObject(metadataBody) }.getOrElse { error ->
            throw AndroidGraphSnapshotException("Snapshot metadata is not valid JSON", error)
        }
        if (!metadata.optBoolean("ok", false)) {
            throw AndroidGraphSnapshotException("Snapshot metadata did not report success")
        }
        val snapshotUrl = runCatching { URL(metadataUrl, metadata.getString("url")) }
            .getOrElse { error ->
                throw AndroidGraphSnapshotException("Snapshot metadata URL is invalid", error)
            }
        val contentEncoding = metadata.optString("content-encoding", "identity")
            .trim()
            .lowercase()
        if (contentEncoding !in setOf("identity", "gzip")) {
            throw AndroidGraphSnapshotException(
                "Unsupported snapshot content encoding: $contentEncoding",
            )
        }

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
            if (cursor.optString("type") != "pull/ok" || cursor.optLong("t", -1) < 0) {
                throw AndroidGraphSnapshotException("Snapshot cursor metadata is invalid")
            }
            metadata.put("t", cursor.getLong("t"))
            return AndroidDownloadedGraphSnapshot(metadata.toString(), snapshot.absolutePath)
        } catch (error: Exception) {
            download.delete()
            decoded?.delete()
            if (error is AndroidGraphSnapshotException) throw error
            throw AndroidGraphSnapshotException("Could not download graph snapshot", error)
        }
    }

    internal fun snapshotMetadataUrl(baseUrl: String, graphId: String): URL {
        var root = baseUrl.trim().trimEnd('/')
        if (root.endsWith("/api")) root = root.removeSuffix("/api")
        val encodedGraphId = URLEncoder.encode(graphId, StandardCharsets.UTF_8.name())
            .replace("+", "%20")
        return runCatching { URL("$root/sync/$encodedGraphId/snapshot/download") }
            .getOrElse { error ->
                throw AndroidGraphSnapshotException("Logseq API base URL is invalid", error)
            }
    }

    internal fun snapshotCursorUrl(baseUrl: String, graphId: String): URL =
        URL(snapshotMetadataUrl(baseUrl, graphId).toString().removeSuffix("/snapshot/download") + "/pull?since=9007199254740991")

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
