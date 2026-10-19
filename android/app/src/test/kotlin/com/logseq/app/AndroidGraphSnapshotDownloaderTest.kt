package com.logseq.app

import logseq.app.AndroidGraphSnapshotDownloader
import org.junit.Assert.assertEquals
import org.junit.Test
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.nio.file.Files

class AndroidGraphSnapshotDownloaderTest {
    @Test
    fun `snapshot endpoints remove api suffix and encode graph ids`() {
        val downloader = AndroidGraphSnapshotDownloader()

        assertEquals(
            "https://sync.example.com/sync/graph%20id/snapshot/download",
            downloader.snapshotMetadataUrl("https://sync.example.com/api/", "graph id").toString(),
        )
        assertEquals(
            "https://sync.example.com/sync/graph%20id/pull?since=9007199254740991",
            downloader.snapshotCursorUrl("https://sync.example.com/api/", "graph id").toString(),
        )
    }

    @Test
    fun `downloads a dev snapshot without added metadata fields or row count header`() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val requested = mutableListOf<String>()
        val bytes = byteArrayOf(0, 0, 0, 3, 65, 66, 67)
        server.createContext("/sync/graph") { exchange ->
            requested += exchange.requestURI.path
            val body = when (exchange.requestURI.path) {
                "/sync/graph/pull" -> """{"type":"pull/ok","t":42,"txs":[]}""".toByteArray()
                "/sync/graph/snapshot/download" -> """{"ok":true,"url":"/sync/graph/snapshot/stream"}""".toByteArray()
                else -> bytes
            }
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        val directory = Files.createTempDirectory("logseq-dev-snapshot").toFile()
        try {
            val result = AndroidGraphSnapshotDownloader().download(
                "http://127.0.0.1:${server.address.port}", "graph", "token", directory.path,
            )
            assertEquals("/sync/graph/pull", requested.first())
            assertEquals(bytes.toList(), java.io.File(result.filePath).readBytes().toList())
        } finally {
            server.stop(0)
            directory.deleteRecursively()
        }
    }
}
