package com.logseq.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidIncomingShareTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun systemOffersLogseqForSingleAndMultipleAttachments() {
        for (action in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            for (mime in listOf("text/plain", "image/png", "audio/mp4", "video/mp4", "application/pdf", "text/markdown", "application/octet-stream", "application/zip")) {
                val intent = Intent(action).setType(mime).setPackage(context.packageName)
                assertTrue("$action $mime must be accepted by the installed app",
                    context.packageManager.queryIntentActivities(intent, 0).any { it.activityInfo.name == MainActivity::class.java.name })
            }
        }
    }

    @Test fun sharedDocumentUrisPreserveOriginalBytesAndMissingUrisAreRejected(): Unit = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val activity = withContext(Dispatchers.Main) { ImportActivity(context) }
        val importer = AndroidAssetImporter(activity, scope)
        val root = File(context.cacheDir, "incoming-share-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            for ((name, bytes) in listOf("Audio.m4a" to "ftypM4A", "Video.mp4" to "ftypmp42", "Document.pdf" to "%PDF-1.4", "Notes.md" to "# Notes", "Archive.zip" to "PK-data")) {
                val source = File(root, name).apply { writeText(bytes) }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", source)
                val asset = requireNotNull(importer.importShared(uri))
                val destination = File(asset.getValue("localPath") as String)
                try {
                    assertEquals(name, asset["title"])
                    assertArrayEquals(source.readBytes(), destination.readBytes())
                    assertEquals(source.length().toInt(), asset["size"])
                } finally { destination.delete() }
            }
            assertNull(importer.importShared(Uri.fromFile(File(root, "missing.pdf"))))
            assertNull(importer.importShared(Uri.fromFile(File(root, "empty.pdf").apply { createNewFile() })))
        } finally { scope.cancel(); root.deleteRecursively() }
    }

    private class ImportActivity(context: Context) : Activity() {
        init { attachBaseContext(context) }
    }
}
