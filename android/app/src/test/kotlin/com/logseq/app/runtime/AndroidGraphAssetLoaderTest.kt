package com.logseq.app.runtime

import java.io.File
import java.net.ServerSocket
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AndroidGraphAssetLoaderTest {
    @Test fun cachedImageDoesNotDownload() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("asset-test-").toFile()
        try {
            val image = File(directory, "cached.png").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val loader = AndroidGraphAssetLoader(directory) { request ->
                assertEquals("prepareAssetDownload", action(request))
                JSONObject().put("ok", true).put("result", JSONObject().put("localPath", image.path)).toString()
            }
            assertEquals(image.path, loader.load("image", "png"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun failedDownloadCanRetryAndCachesExactBytesWithGraphOwnership() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("asset-test-").toFile()
        val bytes = byteArrayOf(0, 1, -1, 13, 10, 65)
        ServerSocket(0).use { server ->
            val worker = thread {
                repeat(2) { attempt -> server.accept().use { socket ->
                    val input = socket.getInputStream().bufferedReader()
                    val lines = generateSequence { input.readLine() }.takeWhile { it.isNotEmpty() }.toList()
                    assertTrue(lines.any { it.equals("Authorization: Bearer token", true) })
                    socket.getOutputStream().apply {
                        write((if (attempt == 0) "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n"
                            else "HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\n\r\n").toByteArray())
                        if (attempt > 0) write(bytes)
                        flush()
                    }
                } }
            }
            try {
                val cached = File(directory, "cached.png")
                val loader = AndroidGraphAssetLoader(File(directory, "downloads")) { request ->
                    val payload = JSONObject(JSONObject(request).getJSONObject("params").getString("payload"))
                    if (action(request) == "prepareAssetDownload") {
                        JSONObject().put("ok", true).put("result", JSONObject().put("graphId", "graph-1")
                            .put("request", JSONObject().put("url", "http://127.0.0.1:${server.localPort}/image")
                                .put("method", "GET").put("token", "token"))).toString()
                    } else {
                        assertEquals("graph-1", payload.getString("graphId"))
                        assertEquals("image", payload.getString("uuid"))
                        cached.writeBytes(File(payload.getString("path")).readBytes())
                        JSONObject().put("ok", true).put("result", JSONObject().put("localPath", cached.path)).toString()
                    }
                }
                assertTrue(runCatching { loader.load("image", "png") }.isFailure)
                assertEquals(cached.path, loader.load("image", "png"))
                assertArrayEquals(bytes, cached.readBytes())
                assertTrue(File(directory, "downloads").listFiles().orEmpty().isEmpty())
            } finally { worker.join(5_000); directory.deleteRecursively() }
        }
    }

    @Test fun graphSwitchRejectionDoesNotLeakTemporaryFiles() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("asset-test-").toFile()
        ServerSocket(0).use { server ->
            val worker = thread { server.accept().use { socket ->
                val input = socket.getInputStream().bufferedReader()
                while (!input.readLine().isNullOrEmpty()) Unit
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc".toByteArray())
            } }
            try {
                val loader = AndroidGraphAssetLoader(directory) { request ->
                    if (action(request) == "prepareAssetDownload")
                        """{"ok":true,"result":{"graphId":"old","request":{"url":"http://127.0.0.1:${server.localPort}/image","headers":{}}}}"""
                    else """{"ok":false,"error":{"message":"Graph changed"}}"""
                }
                assertEquals("Graph changed", runCatching { loader.load("image", "png") }.exceptionOrNull()?.message)
                assertTrue(directory.listFiles().orEmpty().isEmpty())
            } finally { worker.join(5_000); directory.deleteRecursively() }
        }
    }

    private fun action(request: String) = JSONObject(request).getJSONObject("params").getString("action")
}
