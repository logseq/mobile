package com.logseq.app.runtime

import java.io.InputStream
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidWebSocketUploadTest {
    private fun frame(input: InputStream): String {
        val header = input.readNBytes(2)
        check(header.size == 2 && header[0].toInt() and 15 == 1)
        var size = header[1].toInt() and 127
        if (size == 126) size = ByteBuffer.wrap(input.readNBytes(2)).short.toInt() and 65535
        val mask = input.readNBytes(4)
        val data = input.readNBytes(size)
        return data.mapIndexed { index, byte -> (byte.toInt() xor mask[index % 4].toInt()).toByte() }
            .toByteArray().toString(Charsets.UTF_8)
    }

    private fun checkUpload(reject: Boolean) = runBlocking {
        ServerSocket(0).use { server ->
            val url = "ws://127.0.0.1:${server.localPort}/sync/graph"
            val received = CompletableFuture<String>()
            val worker = Thread {
                try {
                    server.accept().use { socket ->
                        socket.soTimeout = 5000
                        val input = socket.getInputStream()
                        val headers = StringBuilder()
                        while (!headers.endsWith("\r\n\r\n")) headers.append(input.read().also { check(it >= 0) }.toChar())
                        val key = headers.lines().first { it.startsWith("Sec-WebSocket-Key:", ignoreCase = true) }.substringAfter(':').trim()
                        val accept = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1")
                            .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()))
                        val output = socket.getOutputStream()
                        output.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n".toByteArray())
                        output.flush()
                        fun send(body: String) {
                            val data = body.toByteArray()
                            check(data.size < 126)
                            output.write(byteArrayOf(0x81.toByte(), data.size.toByte()))
                            output.write(data)
                            output.flush()
                        }
                        assertEquals("pull", JSONObject(frame(input)).getString("type"))
                        send("""{"type":"pull/ok","t":41,"txs":[]}""")
                        received.complete(frame(input))
                        send(if (reject) """{"type":"tx/reject","reason":"invalid tx"}"""
                            else """{"type":"tx/batch/ok","t-before":41,"t":42,"txs":[]}""")
                        input.read()
                    }
                } catch (error: Throwable) { received.completeExceptionally(error) }
            }
            worker.isDaemon = true
            worker.start()
            var completed: JSONObject? = null
            var uploads = 0
            val call: suspend (String) -> String = { wire ->
                val request = JSONObject(wire)
                val params = request.optJSONObject("params") ?: JSONObject()
                val payload = params.optString("payload").takeIf { it.isNotEmpty() && it != "null" }?.let(::JSONObject) ?: JSONObject()
                val commands = JSONArray()
                var pending: Any = JSONObject.NULL
                when (params.optString("action")) {
                    "beginSyncTransport" -> commands.put(JSONObject().put("type", "connect").put("url", url))
                    "syncTransportEvent" -> when (payload.optString("type")) {
                        "opened" -> {
                            commands.put(JSONObject().put("type", "send").put("body", """{"type":"pull","since":41}"""))
                            commands.put(JSONObject().put("type", "sync-pending"))
                        }
                        "frame" -> {
                            val body = payload.getString("body")
                            if (JSONObject(body).getString("type") == "pull/ok") commands.put(JSONObject().put("type", "sync-pending"))
                            else commands.put(JSONObject().put("type", "pending-result").put("id", 1).put("body", body))
                        }
                    }
                    "beginPendingSync" -> if (completed == null) {
                        uploads += 1
                        pending = JSONObject().put("id", 1).put("method", "WS").put("url", url)
                            .put("token", "token").put("contentType", "application/json")
                            .put("body", """{"type":"tx/batch","t-before":41,"txs":[]}""")
                    }
                    "completePendingSync" -> completed = payload
                }
                JSONObject().put("ok", true).put("result", JSONObject()
                    .put("hasPendingSemanticOperations", completed == null)
                    .put("pendingSyncRequest", pending)
                    .put("syncTransport", JSONObject().put("generation", 1).put("graphId", "graph").put("commands", commands))).toString()
            }
            lateinit var sync: AndroidGraphEventsSync
            val pump = AndroidPendingSyncPump(call, {}, { false }, sendWebSocket = { sync.sendPending(it) })
            sync = AndroidGraphEventsSync(call, {}, { pump.run() }, { false }, stopAfterFirstPull = true)
            val result = withTimeout(8000) { sync.runSession(AndroidGraphEventsSync.Connection("graph", url, "token")) }
            assertEquals(AndroidGraphEventsSync.SessionOutcome.Completed, result)
            assertEquals("tx/batch", JSONObject(received.get(1, TimeUnit.SECONDS)).getString("type"))
            assertTrue(uploads > 0)
            val completion = checkNotNull(completed)
            assertEquals(200, completion.getInt("status"))
            assertEquals(if (reject) "tx/reject" else "tx/batch/ok", JSONObject(completion.getString("body")).getString("type"))
            worker.join(1000)
        }
    }

    @Test fun `background uploads receive ACK on the subscription socket`() = checkUpload(false)
    @Test fun `background uploads deliver rejection without blocking reception`() = checkUpload(true)
}
