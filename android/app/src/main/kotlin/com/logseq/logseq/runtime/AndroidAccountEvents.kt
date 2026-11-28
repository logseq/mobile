package com.logseq.logseq.runtime

import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject

internal class AndroidAccountEvents {
    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(25, TimeUnit.SECONDS)
        .build()
    private var socket: WebSocket? = null
    private var graph: GraphSocket? = null
    private var ready = false
    private var unsupported = false

    private data class Incoming(val value: String? = null, val status: Int? = null)

    suspend fun run(baseUrl: String, accessToken: suspend () -> String?, refreshBots: suspend (String) -> Unit) {
        val endpoint = baseUrl.trimEnd('/') + "/events"
        synchronized(this) { unsupported = false }
        var reconnectDelay = 1_000L
        var checked = false
        var nextFallbackRefresh = 0L
        while (currentCoroutineContext().isActive) {
            val token = try {
                accessToken()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
            if (token != null && !checked) {
                val status = withContext(Dispatchers.IO) {
                    try {
                        val call = client.newCall(Request.Builder().url(endpoint).build())
                        call.timeout().timeout(5, TimeUnit.SECONDS)
                        call.execute().use { it.code }
                    } catch (_: IOException) {
                        null
                    }
                }
                checked = status == 426 || status == 404
                synchronized(this) { unsupported = status == 404 }
            }
            var receivedReady = false
            if (token != null && checked && !synchronized(this) { unsupported }) {
                val request = Request.Builder().url(endpoint).header("Authorization", "Bearer $token").build()
                receivedReady = listen(request, refreshBots)
                if (receivedReady) reconnectDelay = 1_000L
            }
            val fallback = synchronized(this) { unsupported }
            val now = android.os.SystemClock.elapsedRealtime()
            if (!receivedReady && token != null && now >= nextFallbackRefresh) {
                nextFallbackRefresh = now + 30_000L
                refreshBots("null")
            }
            delay(if (fallback) 30_000L else reconnectDelay)
            reconnectDelay = (reconnectDelay * 2).coerceAtMost(30_000L)
        }
    }

    private suspend fun listen(request: Request, refreshBots: suspend (String) -> Unit): Boolean {
        val frames = Channel<Incoming>(Channel.UNLIMITED)
        val connection = client.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                frames.trySend(Incoming(value = text))
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
                frames.trySend(Incoming())
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                frames.trySend(Incoming(status = response?.code))
            }
        })
        synchronized(this) { socket = connection }
        var receivedReady = false
        var expiration = System.currentTimeMillis() + 15_000L
        try {
            while (currentCoroutineContext().isActive) {
                val event = withTimeoutOrNull((expiration - System.currentTimeMillis()).coerceAtLeast(1)) {
                    frames.receive()
                } ?: break
                val data = event.value
                if (data == null) {
                    if (event.status == 404 || event.status == 426) synchronized(this) { unsupported = true }
                    break
                }
                val message = runCatching { JSONObject(data) }.getOrNull() ?: continue
                when (message.optString("type")) {
                    "ready" -> if (!receivedReady) {
                        receivedReady = true
                        expiration = message.getLong("expiresAt")
                        synchronized(this) { ready = true }
                        refreshBots("null")
                    }
                    "bots.changed" -> refreshBots(data)
                    "graph.frame", "graph.error" -> synchronized(this) {
                        graph?.takeIf { it.id == message.optString("subscription") }?.deliver(message)
                    }
                }
            }
        } catch (error: CancellationException) {
            throw error
        } finally {
            connection.cancel()
            frames.close()
            synchronized(this) {
                ready = false
                socket = null
                graph?.fail("The account connection closed")
                graph = null
            }
        }
        return receivedReady
    }

    @Synchronized
    fun subscribe(request: Request, graphId: String, onFrame: (String) -> Unit, onFailure: (String) -> Unit): WebSocket? {
        if (unsupported) return null
        val connection = socket?.takeIf { ready } ?: throw IOException("The account connection is not ready")
        graph?.cancel()
        val next = GraphSocket(connection, request, onFrame, onFailure)
        graph = next
        if (!next.sendEvent("graph.subscribe", graphId = graphId)) {
            graph = null
            throw IOException("Could not subscribe to Graph changes")
        }
        return next
    }

    private inner class GraphSocket(
        private val connection: WebSocket,
        private val request: Request,
        private val onFrame: (String) -> Unit,
        private val onFailure: (String) -> Unit,
    ) : WebSocket {
        val id: String = UUID.randomUUID().toString()

        fun sendEvent(type: String, frame: String? = null, graphId: String? = null): Boolean {
            val message = JSONObject().put("type", type).put("subscription", id)
            if (frame != null) message.put("frame", frame)
            if (graphId != null) message.put("graphId", graphId)
            return connection.send(message.toString())
        }

        fun deliver(message: JSONObject) {
            if (message.optString("type") == "graph.error") fail(message.optString("message", "Graph sync failed"))
            else onFrame(message.getString("frame"))
        }

        fun fail(message: String) = onFailure(message)

        override fun request(): Request = request
        override fun queueSize(): Long = connection.queueSize()
        override fun send(text: String): Boolean = synchronized(this@AndroidAccountEvents) {
            graph === this && sendEvent("graph.frame", frame = text)
        }
        override fun send(bytes: ByteString): Boolean = send(bytes.utf8())
        override fun close(code: Int, reason: String?): Boolean = synchronized(this@AndroidAccountEvents) {
            if (graph !== this) return@synchronized false
            graph = null
            sendEvent("graph.unsubscribe")
        }
        override fun cancel() {
            if (close(1000, null)) fail("The Graph connection closed")
        }
    }
}
