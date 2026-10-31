package com.logseq.app

import logseq.app.AndroidRuntimeLog
import logseq.app.AndroidRuntimeLogLevel
import logseq.app.AndroidRuntimeLogSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

class AndroidRuntimeLogTest {
    @Test
    fun `last error survives filtering and ring buffer eviction`() {
        val log = AndroidRuntimeLog(capacity = 1)
        log.append(AndroidRuntimeLogLevel.ERROR, AndroidRuntimeLogSource.UI, "Latest error")
        log.append(AndroidRuntimeLogLevel.INFO, AndroidRuntimeLogSource.CORE, "Connected")
        assertTrue(log.records(source = AndroidRuntimeLogSource.CORE, errorsOnly = true).isEmpty())
        assertEquals("Latest error", log.lastError?.message)
        val snapshot = JSONObject(log.encodedSnapshot(AndroidRuntimeLogSource.CORE, true, true))
        assertEquals(0, snapshot.getJSONArray("records").length())
        assertEquals("Latest error", snapshot.getJSONObject("lastError").getString("message"))
    }

    @Test
    fun `only errors reach the diagnostic alert observer while all records are retained`() {
        val errors = mutableListOf<String>()
        val log = AndroidRuntimeLog(onError = errors::add)
        log.append(AndroidRuntimeLogLevel.ERROR, AndroidRuntimeLogSource.UI, "Authentication failed")
        log.append(AndroidRuntimeLogLevel.ERROR, AndroidRuntimeLogSource.CORE, "Sync failed")
        log.append(AndroidRuntimeLogLevel.INFO, AndroidRuntimeLogSource.UI, "Opened graph")
        assertEquals(listOf("Authentication failed", "Sync failed"), errors)
        assertEquals(3, log.records().size)
    }

    @Test
    fun `bounds filters and orders runtime records like iOS`() {
        val log = AndroidRuntimeLog(capacity = 2)
        log.append(AndroidRuntimeLogLevel.INFO, AndroidRuntimeLogSource.UI, "first", 1)
        log.append(AndroidRuntimeLogLevel.ERROR, AndroidRuntimeLogSource.CORE, "second", 2)
        log.append(AndroidRuntimeLogLevel.INFO, AndroidRuntimeLogSource.CORE, "third", 3)

        assertEquals(listOf("second", "third"), log.records().map { it.message })
        assertEquals(
            listOf("second"),
            log.records(source = AndroidRuntimeLogSource.CORE, errorsOnly = true)
                .map { it.message },
        )
        assertEquals(
            listOf("third", "second"),
            log.records(source = AndroidRuntimeLogSource.CORE, newestFirst = true)
                .map { it.message },
        )
    }

    @Test
    fun `encodes the LG runtime log payload and escapes messages`() {
        val log = AndroidRuntimeLog(capacity = 2)
        log.append(
            AndroidRuntimeLogLevel.ERROR,
            AndroidRuntimeLogSource.UI,
            "Failed \"safely\"\nnext",
            0,
        )

        val encoded = log.encodedRecords(
            source = AndroidRuntimeLogSource.UI,
            errorsOnly = true,
            newestFirst = false,
        )

        assertTrue(encoded.contains("\"level\":\"ERROR\""))
        assertTrue(encoded.contains("\"source\":\"ui\""))
        assertTrue(encoded.contains("Failed \\\"safely\\\"\\nnext"))
    }
}
