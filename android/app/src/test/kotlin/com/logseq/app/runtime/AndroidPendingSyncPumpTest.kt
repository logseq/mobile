package com.logseq.app.runtime

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPendingSyncPumpTest {
    @Test
    fun `native pump waits for the core retry command`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val times = mutableListOf<Long>()
        server.createContext("/request") { exchange ->
            times += System.nanoTime()
            val body = "{}".toByteArray()
            exchange.sendResponseHeaders(if (times.size == 1) 503 else 200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        try {
            var completed = 0
            AndroidPendingSyncPump(callCore = { request ->
                if (JSONObject(request).getJSONObject("params").getString("action") == "completePendingSync") completed += 1
                val pending = if (completed < 2) JSONObject()
                    .put("id", 1).put("method", "GET").put("url", "http://127.0.0.1:${server.address.port}/request")
                    .put("token", "token").put("contentType", "application/json").put("delayMs", if (completed == 1) 100 else 0)
                    else JSONObject.NULL
                JSONObject().put("ok", true).put("result", JSONObject().put("pendingSyncRequest", pending)).toString()
            }, applyResponse = {}, isCancelled = { false }).run()
            assertTrue("The core retry delay must be executed before the next request", times.size == 2 && times[1] - times[0] >= 80_000_000)
        } finally { server.stop(0) }
    }
}
