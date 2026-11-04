package com.logseq.logseq

import android.app.Activity
import android.media.MediaPlayer
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

internal class AndroidAudioPlayer(private val activity: Activity) {
    private var player: MediaPlayer? = null
    private var sessionId = 0
    private var completed = false

    suspend fun start(path: String): Map<String, Any> {
        releasePlayer()
        val file = resolveFile(path)
        require(file.isFile) { "Audio file does not exist" }
        val nextPlayer = MediaPlayer()
        player = nextPlayer
        completed = false
        sessionId += 1
        val activeSessionId = sessionId
        try {
            nextPlayer.setDataSource(file.absolutePath)
            suspendCancellableCoroutine<Unit> { continuation ->
                nextPlayer.setOnPreparedListener { prepared ->
                    prepared.setOnPreparedListener(null)
                    if (continuation.isActive) continuation.resume(Unit)
                }
                nextPlayer.setOnErrorListener { _, what, extra ->
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            IllegalStateException("Could not prepare audio ($what/$extra)")
                        )
                    }
                    true
                }
                continuation.invokeOnCancellation { releasePlayer(activeSessionId) }
                nextPlayer.prepareAsync()
            }
            nextPlayer.setOnCompletionListener {
                if (sessionId == activeSessionId) completed = true
            }
            nextPlayer.setOnErrorListener { _, _, _ ->
                if (sessionId == activeSessionId) completed = true
                true
            }
            nextPlayer.start()
            return mapOf(
                "sessionId" to activeSessionId,
                "durationMs" to nextPlayer.duration.coerceAtLeast(0),
            )
        } catch (error: Throwable) {
            releasePlayer(activeSessionId)
            throw error
        }
    }

    fun pause(sessionId: Int) {
        val active = activePlayer(sessionId) ?: return
        if (active.isPlaying) active.pause()
    }

    fun resume(sessionId: Int) {
        val active = activePlayer(sessionId) ?: return
        if (completed) {
            active.seekTo(0)
            completed = false
        }
        active.start()
    }

    fun status(sessionId: Int): Map<String, Any> {
        val active = activePlayer(sessionId)
        if (active == null || completed) {
            return mapOf(
                "isActive" to false,
                "isPlaying" to false,
                "positionMs" to 0,
                "durationMs" to 0,
            )
        }
        return mapOf(
            "isActive" to true,
            "isPlaying" to active.isPlaying,
            "positionMs" to active.currentPosition.coerceAtLeast(0),
            "durationMs" to active.duration.coerceAtLeast(0),
        )
    }

    fun stop(sessionId: Int) {
        releasePlayer(sessionId)
    }

    fun release() {
        releasePlayer()
    }

    private fun activePlayer(requestedSessionId: Int): MediaPlayer? =
        player?.takeIf { requestedSessionId == sessionId }

    private fun resolveFile(path: String): File {
        val supplied = File(path)
        return if (supplied.isAbsolute) supplied else File(activity.filesDir, path)
    }

    private fun releasePlayer(expectedSessionId: Int? = null) {
        if (expectedSessionId != null && expectedSessionId != sessionId) return
        player?.runCatching { stop() }
        player?.release()
        player = null
        completed = false
    }
}
