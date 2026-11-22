package com.logseq.logseq.runtime

import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class AndroidAppEntryQueueTest {
    @Test fun restartRestoresOrderedSharesAndAcknowledgesOnlySuccess() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("entry-queue").toFile()
        val first = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val second = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val delivered = mutableListOf<AndroidAppEntry>()
            val queue = AndroidAppEntryCoordinator(first, { error("Graph unavailable") }, {}, directory)
            queue.publish(mapOf("kind" to "shared-text", "text" to "First"))
            queue.publish(mapOf("kind" to "shared-text", "text" to "Second"))
            queue.markReady()
            delay(100)
            first.cancel()
            AndroidAppEntryCoordinator(second, { delivered += it }, {}, directory).markReady()
            withTimeout(3_000) { while (delivered.size < 2) delay(10) }
            assertEquals(listOf("First", "Second"), delivered.map { it.text })
            val ids = delivered.map { it.captureUuid }
            assertEquals(2, ids.distinct().size)
            second.cancel()
            val third = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            try {
                AndroidAppEntryCoordinator(third, { fail("Acknowledged share replayed") }, {}, directory).markReady()
                delay(100)
            } finally { third.cancel() }
        } finally { first.cancel(); second.cancel(); directory.deleteRecursively() }
    }

    @Test fun coldWidgetIsRestoredAndOpensBeforeNormalQueueDelivery() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("entry-startup-widget").toFile()
        val first = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val second = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val captureId = "c07fceba-58c0-4bc0-bf39-2479d7491a31"
        try {
            val original = AndroidAppEntryCoordinator(first, { fail("Delivered during graph restore") }, {}, directory)
            original.publish(mapOf("kind" to "shared-text", "text" to "Earlier share"))
            original.publish(mapOf(
                "kind" to "deep-link", "scheme" to "logseq", "host" to "graph",
                "query" to listOf(mapOf("name" to "widget-action", "value" to "open-block")),
                "captureUuid" to captureId,
            ), initialWidgetBlock = true)
            first.cancel()

            val openedWidget = CompletableDeferred<AndroidAppEntry>()
            val deliveredShare = CompletableDeferred<AndroidAppEntry>()
            val restarted = AndroidAppEntryCoordinator(second, {
                if (it.initialWidgetBlock) assertTrue("Widget delivered more than once", openedWidget.complete(it))
                else deliveredShare.complete(it)
            }, {}, directory)
            assertTrue(restarted.hasInitialWidgetBlocks())
            restarted.deliverInitialWidgetBlocks { fail(it.message) }
            assertEquals(captureId, withTimeout(3_000) { openedWidget.await() }.captureUuid)
            assertFalse(restarted.hasInitialWidgetBlocks())
            assertFalse(deliveredShare.isCompleted)

            restarted.markReady()
            assertEquals("Earlier share", withTimeout(3_000) { deliveredShare.await() }.text)
        } finally {
            first.cancel()
            second.cancel()
            directory.deleteRecursively()
        }
    }

    @Test fun cancellationRetainsStableCaptureIdentifierAndAttachmentBytesOutsideCache() = runBlocking {
        val root = kotlin.io.path.createTempDirectory("entry-asset").toFile()
        val cache = File(root, "cache").apply { mkdirs() }
        val source = File(cache, "shared.pdf").apply { writeBytes(byteArrayOf(1, 2, 3, -1)) }
        val queueDirectory = File(root, "queue")
        val first = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val second = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val started = CompletableDeferred<AndroidAppEntry>()
        var errorReported = false
        try {
            val queue = AndroidAppEntryCoordinator(first, { started.complete(it); awaitCancellation() },
                { errorReported = true }, queueDirectory)
            queue.publish(mapOf("kind" to "shared-asset", "asset" to mapOf(
                "uuid" to "c07fceba-58c0-4bc0-bf39-2479d7491a31", "title" to "shared.pdf",
                "assetType" to "pdf", "size" to 4, "checksum" to "checksum", "localPath" to source.path)))
            queue.markReady()
            val original = withTimeout(3_000) { started.await() }
            first.cancel()
            cache.deleteRecursively()
            val replayed = CompletableDeferred<AndroidAppEntry>()
            AndroidAppEntryCoordinator(second, { replayed.complete(it); awaitCancellation() }, {}, queueDirectory).markReady()
            val restored = withTimeout(3_000) { replayed.await() }
            assertEquals(original.captureUuid, restored.captureUuid)
            assertEquals(original.asset!!.uuid, restored.asset!!.uuid)
            assertArrayEquals(byteArrayOf(1, 2, 3, -1), File(restored.asset.localPath).readBytes())
            assertFalse("Activity cancellation is not an import error", errorReported)
        } finally { first.cancel(); second.cancel(); root.deleteRecursively() }
    }

    @Test fun rejectedShareIsDiscardedSoLaterSharesStillArrive() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("entry-rejected").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val delivered = mutableListOf<String?>()
            val errors = mutableListOf<Throwable>()
            val queue = AndroidAppEntryCoordinator(scope, {
                if (it.text == "Rejected") throw AndroidAppEntryRejected("rejected")
                delivered += it.text
            }, { errors += it }, directory)
            queue.publish(mapOf("kind" to "shared-text", "text" to "Rejected"))
            queue.publish(mapOf("kind" to "shared-text", "text" to "Later"))
            queue.markReady()
            withTimeout(3_000) { while (delivered.isEmpty()) delay(10) }
            assertEquals(listOf("Later"), delivered)
            assertTrue(errors.single() is AndroidAppEntryRejected)
            AndroidAppEntryCoordinator(scope, { fail("Rejected share replayed") }, {}, directory).markReady()
            delay(100)
        } finally { scope.cancel(); directory.deleteRecursively() }
    }
}
