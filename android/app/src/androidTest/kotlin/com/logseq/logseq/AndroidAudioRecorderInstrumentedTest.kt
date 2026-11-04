package com.logseq.logseq

import android.Manifest
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlinx.coroutines.runBlocking

@RunWith(AndroidJUnit4::class)
class AndroidAudioRecorderInstrumentedTest {
    @get:Rule
    val microphonePermission: GrantPermissionRule =
        GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    @Test
    fun recordsNonEmptyM4aWithStableMetadata() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val recorder = AndroidAudioRecorder(activity)
                runBlocking { recorder.start() }
                Thread.sleep(800)
                val metadata = recorder.stop()
                val file = File(metadata.getValue("localPath") as String)
                try {
                    assertEquals("m4a", metadata["assetType"])
                    assertTrue((metadata["size"] as Int) > 0)
                    assertEquals(64, (metadata["checksum"] as String).length)
                    assertTrue(file.isFile)
                } finally {
                    file.delete()
                }
            }
        }
    }
}
