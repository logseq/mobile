package com.logseq.app.runtime

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidPendingSyncPumpTest {
    @Test
    fun `sync refreshes authorization before upload and cancels on refresh failure`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val authorization = mutableListOf<String?>()
        server.createContext("/request") { exchange ->
            authorization += exchange.requestHeaders.getFirst("Authorization")
            exchange.sendResponseHeaders(200, 2)
            exchange.responseBody.use { it.write("{}".toByteArray()) }
        }
        server.start()
        try {
            for (refreshFails in listOf(false, true)) {
                val actions = mutableListOf<String>()
                AndroidPendingSyncPump(
                    callCore = { request ->
                        val action = JSONObject(request).getJSONObject("params").getString("action")
                        actions += action
                        val pending = if (action == "beginPendingSync") JSONObject()
                            .put("id", 1).put("method", "GET")
                            .put("url", "http://127.0.0.1:${server.address.port}/request")
                            .put("token", "expired-token").put("contentType", "application/json")
                            else JSONObject.NULL
                        JSONObject().put("ok", true).put("result", JSONObject().put("pendingSyncRequest", pending)).toString()
                    },
                    applyResponse = {}, isCancelled = { false },
                    accessTokenProvider = {
                        if (refreshFails) error("Sign in to connect to Logseq Sync.")
                        "refreshed-token"
                    },
                ).run()
                assertEquals(listOf("beginPendingSync", if (refreshFails) "cancelPendingSync" else "completePendingSync"), actions)
                assertEquals(listOf("Bearer refreshed-token"), authorization)
            }
        } finally { server.stop(0) }
    }

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
