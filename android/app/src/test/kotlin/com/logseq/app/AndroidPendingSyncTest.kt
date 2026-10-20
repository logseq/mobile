package com.logseq.app.runtime

import java.io.File
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AndroidPendingSyncTest {
    @Test fun interruptedUploadRetriesTheSameFileAndIdentity() = runBlocking {
        val file = File.createTempFile("logseq-upload-", ".png")
        val bytes = ByteArray(1024 * 1024) { (it % 256).toByte() }
        file.writeBytes(bytes)
        val server = ServerSocket(0)
        server.soTimeout = 5000
        val requests = AtomicInteger()
        val bodies = mutableListOf<ByteArray>()
        val worker = thread {
            try {
                while (requests.get() < 2) server.accept().use { socket ->
                    socket.soTimeout = 5000
                    val input = socket.getInputStream().buffered()
                    val header = StringBuilder()
                    while (!header.endsWith("\r\n\r\n")) header.append(input.read().toChar())
                    val count = requests.incrementAndGet()
                    assertTrue(header.startsWith("PUT /assets/graph/stable.png "))
                    if (count == 1) {
                        input.read(ByteArray(1024))
                        socket.setSoLinger(true, 0)
                    } else {
                        val length = Regex("(?i)Content-Length: (\\d+)").find(header)!!.groupValues[1].toInt()
                        bodies.add(input.readNBytes(length))
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".toByteArray())
                    }
                }
            } finally { server.close() }
        }
        try {
            var completions = 0
            val pending = AndroidPendingSyncRequest(1, "PUT",
                "http://127.0.0.1:${server.localPort}/assets/graph/stable.png", null, "test", file.path,
                "image/png", mapOf("x-amz-meta-checksum" to "stable-checksum"))
            AndroidPendingSyncPump(callCore = { input ->
                val params = JSONObject(input).getJSONObject("params")
                if (params.getString("action") == "completePendingSync") {
                    completions += 1
                    val completion = JSONObject(params.getString("payload"))
                    if (completions == 2) assertEquals(200, completion.getInt("status"))
                }
                val request = if (completions < 2) JSONObject()
                    .put("id", pending.id).put("method", pending.method).put("url", pending.url)
                    .put("token", pending.token).put("filePath", pending.filePath)
                    .put("contentType", pending.contentType).put("headers", JSONObject(pending.headers))
                    .put("delayMs", if (completions == 1) 10 else 0) else JSONObject.NULL
                JSONObject().put("ok", true).put("result", JSONObject().put("pendingSyncRequest", request)).toString()
            }, applyResponse = {}, isCancelled = { false }).run()
            worker.join(6000)
            assertEquals(2, requests.get())
            assertArrayEquals(bytes, bodies.single())
        } finally {
            server.close()
            file.delete()
            worker.join(1000)
        }
    }

    @Test fun composerAttachmentPersistsThroughTheLocalCoreEffect() = runBlocking {
        var called: JSONObject? = null
        val executor = CoreEffectExecutor(
            callCore = { called = JSONObject(it); "{\"ok\":true,\"result\":{}}" },
            executePlatformEffect = NativeEffectExecutor { NativeEffectResolution.Discard() },
            executeGraphEffect = NativeEffectExecutor { NativeEffectResolution.Discard() },
        )
        val payload = "{\"uuid\":\"stable\",\"localPath\":\"/local/photo.png\"}"
        val result = executor.execute(NativeEffect(id = 1, kind = "send-asset", text = payload))
        assertTrue(result.succeeded)
        assertEquals("executeEffect", called!!.getJSONObject("params").getString("action"))
        assertEquals(payload, JSONObject(called!!.getJSONObject("params").getString("payload")).getString("text"))
    }
}
