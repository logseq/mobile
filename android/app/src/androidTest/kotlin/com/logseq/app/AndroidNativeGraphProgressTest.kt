package com.logseq.app

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.AndroidGraphImportProgress
import com.logseq.app.runtime.NativeCoreSession
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AndroidNativeGraphProgressTest {
    @Test fun actualSnapshotImportDeliversNativePhasesAndRecordCount(): Unit = runBlocking {
        val fixture = requireNotNull(InstrumentationRegistry.getArguments().getString("backgroundGraphFixture"))
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,
            "progress-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val progress = mutableListOf<Triple<String, Long, Long?>>()
        NativeCoreSession.gate.withLock {
            try {
                val rows = JSONArray()
                SQLiteDatabase.openDatabase(fixture, null, SQLiteDatabase.OPEN_READONLY).use { database ->
                    database.rawQuery("SELECT addr, content, addresses FROM kvs ORDER BY addr", null).use { cursor ->
                        while (cursor.moveToNext()) rows.put(JSONArray().put(cursor.getLong(0)).put(cursor.getString(1))
                            .put(if (cursor.isNull(2)) JSONObject.NULL else cursor.getString(2)))
                    }
                }
                val bytes = rows.toString().toByteArray(Charsets.UTF_8)
                val stream = File(root, "download.snapshot").apply {
                    outputStream().use { it.write(ByteBuffer.allocate(4).putInt(bytes.size).array()); it.write(bytes) }
                }
                NativeCore.luiInitialize(3, 4, 1)
                fun request(method: String, params: JSONObject): JSONObject {
                    val result = JSONObject(String(requireNotNull(NativeCore.logseqCall(JSONObject()
                        .put("apiVersion", 1).put("method", method).put("params", params).toString().toByteArray()))))
                    assertTrue(result.toString(), result.optBoolean("ok"))
                    return result
                }
                fun dispatch(action: String, payload: JSONObject) = request("dispatch", JSONObject()
                    .put("action", action).put("payload", payload.toString()))
                request("open", JSONObject().put("path", File(root, "catalog.sqlite").path))
                dispatch("configure", JSONObject().put("baseUrl", "http://127.0.0.1:1").put("token", "")
                    .put("graphId", "progress-qa"))
                AndroidGraphImportProgress.listener = { graph, phase, done, total ->
                    assertEquals("progress-qa", graph)
                    progress += Triple(phase, done, total)
                }
                dispatch("importSnapshot", JSONObject().put("graphId", "progress-qa")
                    .put("activePath", File(root, "graph.sqlite").path)
                    .put("checkpointPath", File(root, "sync.checkpoint").path).put("isEncrypted", false)
                    .put("downloadPath", stream.path).put("metadataBody", JSONObject().put("ok", true)
                        .put("url", "snapshot").put("t", 0).put("schema-version", "65.34")
                        .put("row-count", rows.length()).toString()))
                assertTrue("The actual core import must emit progress", progress.any { it.first == "importing" })
                assertTrue("Opening must include the actual record count", progress.any {
                    it.first == "opening" && it.second > 0 && it.second == it.third
                })
            } finally {
                AndroidGraphImportProgress.listener = null
                NativeCore.luiDispose()
                root.deleteRecursively()
            }
        }
    }
}
