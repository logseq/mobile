package com.logseq.app.runtime

import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Executes socket commands from the shared core; frames remain opaque here.
internal class AndroidGraphEventsSync(
    private val callCore: suspend (String) -> String,
    private val applyResponse: suspend (String) -> Unit,
    private val onChangesApplied: suspend () -> Unit,
    private val isCancelled: () -> Boolean,
    private val stopAfterFirstPull: Boolean = false,
) {
    data class Connection(val graphId: String, val baseUrl: String, val accessToken: String)

    sealed class SessionOutcome {
        object Completed : SessionOutcome()
        object SnapshotRequired : SessionOutcome()
        data class Retry(val delayMilliseconds: Long, val message: String?) : SessionOutcome()
        object Stopped : SessionOutcome()
    }

    private var generation = -1
    private var graphId = ""
    @Volatile private var pendingWebSocket: AndroidPendingWebSocket? = null

    suspend fun sendPending(request: AndroidPendingSyncRequest): AndroidPendingSyncResult? =
        pendingWebSocket?.send(request)

    private sealed class Frame {
        data class Text(val value: String) : Frame()
        data class Failure(val message: String) : Frame()
        object Closed : Frame()
        object PumpFinished : Frame()
    }

    suspend fun runSession(connection: Connection): SessionOutcome = coroutineScope {
        graphId = connection.graphId
        val frames = Channel<Frame>(capacity = Channel.UNLIMITED)
        val pendingSignals = Channel<Unit>(capacity = Channel.CONFLATED)
        val client = OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .build()
        var socket: WebSocket? = null
        var receivedFrame = false
        val pendingJob: Job = launch {
            for (signal in pendingSignals) {
                onChangesApplied()
                frames.send(Frame.PumpFinished)
            }
        }
        try {
            var transport = dispatch("beginSyncTransport", "{}")
            generation = transport.getInt("generation")
            if (transport.getString("graphId") != graphId) return@coroutineScope SessionOutcome.Stopped
            while (!isCancelled()) {
                val commands = ArrayDeque<JSONObject>()
                fun enqueue(state: JSONObject) {
                    val values = state.getJSONArray("commands")
                    for (index in 0 until values.length()) commands.addLast(values.getJSONObject(index))
                }
                enqueue(transport)
                while (commands.isNotEmpty()) {
                    val command = commands.removeFirst()
                    when (command.getString("type")) {
                        "connect" -> {
                            val request = Request.Builder().url(command.getString("url"))
                                .header("Authorization", "Bearer ${connection.accessToken}").build()
                            socket = openSocket(client, request, frames, isCancelled)
                            pendingWebSocket = AndroidPendingWebSocket(socket, command.getString("url"))
                            transport = event("opened")
                            enqueue(transport)
                        }
                        "send" -> check(socket?.send(command.getString("body")) == true) { "WebSocket send failed" }
                        "pending-result" -> pendingWebSocket?.complete(command.getLong("id"), command.getString("body"))
                        "close" -> { socket?.cancel(); socket = null }
                        "retry" -> return@coroutineScope SessionOutcome.Retry(
                            command.getLong("delayMs"), transport.optString("error").takeIf { it.isNotEmpty() && it != "null" }
                        )
                        "snapshot" -> return@coroutineScope SessionOutcome.SnapshotRequired
                        "sync-pending" -> {
                            pendingSignals.trySend(Unit)
                        }
                        else -> error("Unsupported sync transport command")
                    }
                }
                if (socket == null) return@coroutineScope SessionOutcome.Stopped
                transport = when (val frame = frames.receive()) {
                    is Frame.Text -> {
                        event("frame", body = frame.value).also { state ->
                            val commands = state.getJSONArray("commands")
                            if ((0 until commands.length()).any { commands.getJSONObject(it).getString("type") == "sync-pending" })
                                receivedFrame = true
                        }
                    }
                    is Frame.Failure -> event("failed", message = frame.message)
                    Frame.Closed -> event("closed")
                    Frame.PumpFinished -> {
                        if (stopAfterFirstPull && receivedFrame) {
                            val response = callCore("""{"apiVersion":1,"method":"snapshot","params":{}}""")
                            applyResponse(response)
                            val result = JSONObject(response).getJSONObject("result")
                            if (!result.optBoolean("hasPendingSemanticOperations") && result.isNull("pendingSyncRequest")) {
                                event("cancelled")
                                return@coroutineScope SessionOutcome.Completed
                            }
                        }
                        JSONObject(transport.toString()).put("commands", org.json.JSONArray())
                    }
                }
            }
            event("cancelled")
            return@coroutineScope SessionOutcome.Stopped
        } catch (error: kotlinx.coroutines.CancellationException) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                if (generation >= 0) runCatching { event("cancelled") }
            }
            throw error
        } catch (error: Throwable) {
            if (generation < 0) throw error
            val transport = event("failed", message = error.message ?: error.toString())
            return@coroutineScope retryOutcome(transport)
        } finally {
            pendingWebSocket?.close()
            pendingWebSocket = null
            pendingSignals.close()
            pendingJob.cancel()
            socket?.cancel()
            frames.close()
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }

    suspend fun completeSnapshot(succeeded: Boolean): Long {
        val transport = event(if (succeeded) "snapshot-applied" else "snapshot-failed",
            message = if (succeeded) null else "Snapshot refresh failed")
        return (retryOutcome(transport) as? SessionOutcome.Retry)?.delayMilliseconds ?: 0
    }

    private fun retryOutcome(transport: JSONObject): SessionOutcome {
        val commands = transport.getJSONArray("commands")
        for (index in 0 until commands.length()) {
            val command = commands.getJSONObject(index)
            if (command.getString("type") == "retry") {
                return SessionOutcome.Retry(command.getLong("delayMs"), transport.optString("error"))
            }
        }
        return SessionOutcome.Stopped
    }

    private suspend fun event(type: String, body: String? = null, message: String? = null): JSONObject {
        val payload = JSONObject().put("type", type).put("generation", generation).put("graphId", graphId)
        if (body != null) payload.put("body", body)
        if (message != null) payload.put("message", message)
        return dispatch("syncTransportEvent", payload.toString())
    }

    private suspend fun dispatch(action: String, payload: String? = null): JSONObject {
        val params = JSONObject().put("action", action)
        if (payload != null) params.put("payload", payload)
        val request = JSONObject()
            .put("apiVersion", 1)
            .put("method", "dispatch")
            .put("params", params)
            .toString()
        val response = callCore(request)
        applyResponse(response)
        val envelope = JSONObject(response)
        check(envelope.optBoolean("ok")) { envelope.optJSONObject("error")?.optString("message") ?: "Core sync transport failed" }
        return envelope.getJSONObject("result").getJSONObject("syncTransport")
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

}
