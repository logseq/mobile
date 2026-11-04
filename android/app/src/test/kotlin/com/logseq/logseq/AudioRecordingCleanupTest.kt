package com.logseq.logseq

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

class AudioRecordingCleanupTest {
    @Test
    fun failedCodecStopStillReleasesTheMicrophoneEncoderAndFile() {
        val stopped = IllegalStateException("Codec already stopped")
        val closed = IOException("Recognition pipe already closed")
        val released = mutableListOf<String>()
        val failure = releaseAudioResources(
            { released += "microphone" },
            { throw stopped },
            { released += "codec" },
            { throw closed },
            { released += "file" },
        )
        assertEquals(listOf("microphone", "codec", "file"), released)
        assertSame(stopped, failure)
        assertEquals(listOf(closed), failure!!.suppressed.toList())
    }

    @Test
    fun successfulCleanupDoesNotReportAnError() {
        assertNull(releaseAudioResources({}, {}))
    }

    @Test
    fun captureFailureDoesNotEscapeAnAutomaticStopCoroutine() = runBlocking {
        val failure = IllegalStateException("Microphone disconnected")
        val capture = CompletableDeferred<Unit>().apply { completeExceptionally(failure) }
        val serviceStop = launch {
            val reported = stopAudioCapture { capture.await() }
            assertEquals(failure.javaClass, reported?.javaClass)
            assertEquals(failure.message, reported?.message)
        }
        serviceStop.join()
        assertEquals(false, serviceStop.isCancelled)
    }

    @Test
    fun stoppingPreservesCoroutineCancellation() = runBlocking {
        val cancelled = CancellationException("Service destroyed")
        try {
            stopAudioCapture { throw cancelled }
            fail("Cancellation was swallowed")
        } catch (actual: CancellationException) {
            assertSame(cancelled, actual)
        }
    }
}
