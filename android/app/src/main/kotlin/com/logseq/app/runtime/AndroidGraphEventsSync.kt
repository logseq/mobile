package com.logseq.app.runtime

import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Kotlin port of iOS runGraphEventsOnce (ViewModel.swift): opens the
// /sync/<graphID> WebSocket, pulls the journal since the applied server
// cursor, forwards every pull/ok frame to the core through the
// `applySyncEvent` dispatch action, and reports connectivity through the
// `startWebSocket`/`stopWebSocket` actions so syncConnected drives the
// status dot the same way it does on iOS.
internal class AndroidGraphEventsSync(
    private val callCore: suspend (String) -> String,
    private val applyResponse: suspend (String) -> Unit,
    private val appliedServerT: () -> Long,
    private val onChangesApplied: suspend () -> Unit,
    private val isCancelled: () -> Boolean,
    private val log: (String, String) -> Unit,
) {
    data class Connection(val graphId: String, val baseUrl: String, val accessToken: String)

    sealed class SessionOutcome {
        // The core asked for a fresh snapshot (cursor reset); the caller
        // should re-open/re-import the graph before reconnecting.
        object SnapshotRequired : SessionOutcome()
        // The socket failed; reconnecting with backoff is worthwhile.
        data class Failed(val message: String) : SessionOutcome()
    }

    private sealed class Frame {
        data class Text(val value: String) : Frame()
        data class Failure(val message: String) : Frame()
        object Closed : Frame()
    }

    suspend fun runSession(connection: Connection): SessionOutcome {
        val cursor = appliedServerT()
        if (cursor < 0) {
            log("warn", "graph events skipped: no appliedServerT yet")
            return SessionOutcome.SnapshotRequired
        }
        val url = webSocketUrl(connection.baseUrl, connection.graphId)
            ?: return SessionOutcome.Failed("Unsupported sync base URL: ${connection.baseUrl}")
        val frames = Channel<Frame>(capacity = Channel.UNLIMITED)
        val client = OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .build()
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${connection.accessToken}")
            .build()
        var socketRef: WebSocket? = null
        try {
            android.util.Log.d("GraphEvents", "connecting $url")
            val socket = openSocket(client, request, frames, isCancelled)
            socketRef = socket
            try {
                android.util.Log.d("GraphEvents", "connected; startWebSocket")
                val opened = dispatch("startWebSocket")
                dispatchError(opened)?.let { return SessionOutcome.Failed(it) }
                android.util.Log.d("GraphEvents", "pull since=$cursor")
                sendPull(socket, cursor)
                var pullInFlight = true
                var latestNotifiedServerT = cursor
                while (!isCancelled()) {
                    when (val frame = frames.receive()) {
                        is Frame.Failure ->
                            return SessionOutcome.Failed(frame.message)
                        Frame.Closed ->
                            return SessionOutcome.Failed("WebSocket closed")
                        is Frame.Text -> {
                            val envelope = JSONObject(frame.value)
                            val frameType = envelope.optString("type")
                            android.util.Log.d("GraphEvents", "frame type=$frameType")
                            when (frameType) {
                                "pull/ok" -> {
                                    val applied = dispatch("applySyncEvent", envelope.put("graphId", connection.graphId).toString())
                                    dispatchError(applied)?.let { code ->
                                        return if (code == "snapshot_required") {
                                            SessionOutcome.SnapshotRequired
                                        } else {
                                            SessionOutcome.Failed(code)
                                        }
                                    }
                                    pullInFlight = false
                                    onChangesApplied()
                                    val currentCursor = appliedServerT()
                                    if (currentCursor >= 0 && latestNotifiedServerT > currentCursor) {
                                        sendPull(socket, currentCursor)
                                        pullInFlight = true
                                    }
                                }
                                "hello", "changed" -> {
                                    val serverT = envelope.optLong("t", -1)
                                    if (serverT >= 0) {
                                        latestNotifiedServerT = maxOf(latestNotifiedServerT, serverT)
                                    }
                                    if (!pullInFlight) {
                                        val currentCursor = appliedServerT()
                                        if (currentCursor < 0) {
                                            return SessionOutcome.Failed("appliedServerT became invalid")
                                        }
                                        sendPull(socket, currentCursor)
                                        pullInFlight = true
                                    }
                                }
                                "error" ->
                                    return SessionOutcome.Failed(
                                        envelope.optString("message", "sync error frame")
                                    )
                                else -> continue
                            }
                        }
                    }
                }
                return SessionOutcome.Failed("cancelled")
            } finally {
                socket.close(1000, null)
            }
        } catch (error: Throwable) {
            return SessionOutcome.Failed(error.message ?: error.toString())
        } finally {
            socketRef?.cancel()
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
            // iOS dispatches stopWebSocket unless the session ended with a
            // snapshot_required stream error; keeping it unconditional is
            // equivalent here because a snapshot re-import re-opens the
            // socket and dispatches startWebSocket again.
            if (!isCancelled()) {
                runCatching { dispatch("stopWebSocket") }
            }
        }
    }

    private suspend fun dispatch(action: String, payload: String? = null): String {
        val params = JSONObject().put("action", action)
        if (payload != null) params.put("payload", payload)
        val request = JSONObject()
            .put("apiVersion", 1)
            .put("method", "dispatch")
            .put("params", params)
            .toString()
        val response = callCore(request)
        applyResponse(response)
        return response
    }

    private fun dispatchError(response: String): String? =
        runCatching {
            val error = JSONObject(response).optJSONObject("error") ?: return null
            error.optString("code").ifEmpty { error.optString("message") }
        }.getOrNull()

    private fun sendPull(socket: WebSocket, since: Long) {
        socket.send(JSONObject()
            .put("since", since)
            .put("type", "pull")
            .toString())
    }

    private suspend fun openSocket(
        client: OkHttpClient,
        request: Request,
        frames: Channel<Frame>,
        isCancelled: () -> Boolean,
    ): WebSocket = withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { continuation: CancellableContinuation<WebSocket> ->
            val holder = arrayOfNulls<WebSocket>(1)
            holder[0] = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (continuation.isActive) continuation.resume(webSocket)
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    frames.trySend(Frame.Text(text))
                }

                override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                    frames.trySend(Frame.Text(bytes.utf8()))
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    frames.trySend(Frame.Closed)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    frames.trySend(
                        Frame.Failure(
                            response?.let { "HTTP ${it.code}" }
                                ?: (t.message ?: t.toString())
                        )
                    )
                    if (continuation.isActive) {
                        continuation.resumeWithException(t)
                    }
                }
            })
            continuation.invokeOnCancellation { holder[0]?.cancel() }
            if (isCancelled()) holder[0]?.cancel()
        }
    }

    companion object {
        // Mirrors LogseqGraphSyncHTTP.webSocketRequest: http(s) -> ws(s),
        // path /sync/<graphID>.
        internal fun webSocketUrl(baseUrl: String, graphId: String): String? {
            val trimmed = baseUrl.trimEnd('/')
            val scheme = when {
                trimmed.startsWith("http://") -> "ws://"
                trimmed.startsWith("https://") -> "wss://"
                trimmed.startsWith("ws://") || trimmed.startsWith("wss://") -> ""
                else -> return null
            }
            val rest = if (scheme.isEmpty()) trimmed else scheme + trimmed.substringAfter("://")
            return "$rest/sync/$graphId"
        }

        // iOS reconnect cadence: 1,2,4,8,16,30,30,...
        internal fun backoffSeconds(attempt: Int): Long = when {
            attempt <= 0 -> 1
            attempt == 1 -> 2
            attempt == 2 -> 4
            attempt == 3 -> 8
            attempt == 4 -> 16
            else -> 30
        }
    }
}
