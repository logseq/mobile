package com.logseq.app

import kotlinx.coroutines.runBlocking
import logseq.app.AndroidGraphSnapshotDownloader
import org.junit.Assert.assertEquals
import org.junit.Test
import org.json.JSONObject
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.nio.file.Files

class AndroidGraphSnapshotDownloaderTest {
    @Test
    fun `downloads the shared snapshot plan and preserves binary bytes`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val requested = mutableListOf<String>()
        val progress = mutableListOf<Triple<String, Long, Long?>>()
        val bytes = byteArrayOf(0, 0, 0, 3, 65, 66, 67)
        server.createContext("/sync/graph") { exchange ->
            requested += exchange.requestURI.path
            val body = when (exchange.requestURI.path) {
                "/sync/graph/snapshot/download" -> """{"ok":true,"url":"/sync/graph/snapshot/stream","t":42}""".toByteArray()
                else -> bytes
            }
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        val directory = Files.createTempDirectory("logseq-dev-snapshot").toFile()
        try {
            val baseUrl = "http://127.0.0.1:${server.address.port}"
            val result = AndroidGraphSnapshotDownloader().download(
                baseUrl, "graph", "token", directory.path,
                onProgress = { phase, done, total -> progress += Triple(phase, done, total) },
                callCore = { request ->
                    val action = JSONObject(request).getJSONObject("params").getString("action")
                    val fields = if (action == "snapshotDownloadPlan") {
                        JSONObject().put("metadataURL", "$baseUrl/sync/graph/snapshot/download")
                    } else {
                        JSONObject().put("downloadURL", "/sync/graph/snapshot/stream")
                            .put("metadataBody", """{"ok":true,"url":"/sync/graph/snapshot/stream","t":42}""")
                    }
                    JSONObject().put("ok", true).put("result", fields).toString()
                },
            )
            org.junit.Assert.assertTrue(progress.any { it.first == "downloading" && it.second == bytes.size.toLong() && it.third == bytes.size.toLong() })
            assertEquals(listOf("/sync/graph/snapshot/download", "/sync/graph/snapshot/stream"), requested)
            assertEquals(42, JSONObject(result.metadataBody).getInt("t"))
            assertEquals(bytes.toList(), java.io.File(result.filePath).readBytes().toList())
        } finally {
            server.stop(0)
            directory.deleteRecursively()
        }
    }
    @Test fun gzipDownloadReportsDecodingAndRejectedDownloadCleansArtifacts() = runBlocking {
        val raw = ByteArray(100_000) { (it % 251).toByte() }
        val compressed = java.io.ByteArrayOutputStream().also { bytes ->
            java.util.zip.GZIPOutputStream(bytes).use { it.write(raw) }
        }.toByteArray()
        var rejected = false
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/metadata") { exchange ->
            val metadata = "{}".toByteArray()
            exchange.sendResponseHeaders(200, metadata.size.toLong())
            exchange.responseBody.use { it.write(metadata) }
        }
        server.createContext("/data") { exchange ->
            exchange.sendResponseHeaders(if (rejected) 503 else 200, if (rejected) -1 else compressed.size.toLong())
            exchange.responseBody.use { if (!rejected) it.write(compressed) }
        }
        server.start()
        val directory = Files.createTempDirectory("snapshot-gzip").toFile()
        try {
            val progress = mutableListOf<String>()
            val base = "http://127.0.0.1:${server.address.port}"
            val call: suspend (String) -> String = { request ->
                val action = JSONObject(request).getJSONObject("params").getString("action")
                val result = if (action == "snapshotDownloadPlan") JSONObject().put("metadataURL", "$base/metadata")
                    else JSONObject().put("downloadURL", "/data").put("metadataBody", "{}")
                JSONObject().put("ok", true).put("result", result).toString()
            }
            val result = AndroidGraphSnapshotDownloader().download(base, "g", "token", directory.path,
                callCore = call, onProgress = { phase, _, _ -> progress += phase })
            org.junit.Assert.assertArrayEquals(raw, java.io.File(result.filePath).readBytes())
            org.junit.Assert.assertTrue(progress.contains("decoding"))
            java.io.File(result.filePath).delete()
            rejected = true
            org.junit.Assert.assertTrue(runCatching {
                AndroidGraphSnapshotDownloader().download(base, "g", "token", directory.path, call)
            }.isFailure)
            org.junit.Assert.assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally { server.stop(0); directory.deleteRecursively() }
    }

}
