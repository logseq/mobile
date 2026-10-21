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
            assertEquals(listOf("/sync/graph/snapshot/download", "/sync/graph/snapshot/stream"), requested)
            assertEquals(42, JSONObject(result.metadataBody).getInt("t"))
            assertEquals(bytes.toList(), java.io.File(result.filePath).readBytes().toList())
        } finally {
            server.stop(0)
            directory.deleteRecursively()
        }
    }
}
