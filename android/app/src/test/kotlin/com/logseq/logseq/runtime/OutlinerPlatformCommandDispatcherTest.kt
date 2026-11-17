package com.logseq.logseq.runtime

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class OutlinerPlatformCommandDispatcherTest {
    private val asset = AndroidImportedAsset("asset", "Photo.jpg", "image/jpeg", 42, "hash", "/photo.jpg")

    private fun response(revision: Int) = """{"ok":true,"result":{
        "outlinerCommandRevision":$revision,"outlinerCommands":[{"type":"pickAttachment","uuid":"block"}]}}
    """

    @Test fun rejectedAttachmentIsReportedWithoutCrashingOrReplayingThePicker() = runBlocking {
        val failures = mutableListOf<Exception>()
        var calls = 0
        val dispatcher = OutlinerPlatformCommandDispatcher(
            onBatch = {
                calls++
                asset.requireAccepted("""{"ok":false,"error":{"code":"asset_projection_failed",
                    "message":"asset destination is not available"}}""")
            },
            onError = { failures += it },
        )
        dispatcher.deliver(response(1))
        dispatcher.deliver(response(1))
        dispatcher.deliver(response(2))
        assertEquals(2, calls)
        assertEquals(2, failures.size)
        assertEquals("Could not add Photo.jpg (asset_projection_failed): asset destination is not available",
            failures.first().message)
    }

    @Test fun successfulAttachmentAndLaterCommandsStillRun() = runBlocking {
        val revisions = mutableListOf<Long>()
        val dispatcher = OutlinerPlatformCommandDispatcher(onBatch = {
            asset.requireAccepted("""{"ok":true,"result":{}}""")
            revisions += it.revision
        }, onError = { throw AssertionError(it) })
        dispatcher.deliver(response(1))
        dispatcher.deliver(response(2))
        assertEquals(listOf(1L, 2L), revisions)
    }

    @Test fun activityCancellationIsPropagatedWithoutReportingAnImportError() = runBlocking {
        val cancelled = CancellationException("Activity destroyed")
        val failures = mutableListOf<Exception>()
        val dispatcher = OutlinerPlatformCommandDispatcher(onBatch = { throw cancelled }, onError = { failures += it })
        try {
            dispatcher.deliver(response(1))
            fail("Cancellation must propagate")
        } catch (error: CancellationException) {
            assertSame(cancelled, error)
        }
        assertTrue(failures.isEmpty())
    }
}
