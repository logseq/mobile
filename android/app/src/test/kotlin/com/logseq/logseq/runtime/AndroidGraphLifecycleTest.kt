package com.logseq.logseq.runtime

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidGraphLifecycleTest {
    private class Storage : AndroidGraphStorage {
        var downloads = 0
        val cleaned = mutableListOf<String>()
        override fun loadStorageState() = AndroidStorageState(
            "/tmp/catalog", "/tmp/graphs", "http://localhost", "plain-1", listOf("plain-1"),
        )
        override suspend fun downloadGraphSnapshot(
            baseUrl: String, graphId: String, accessToken: String, workingDirectory: String,
            callCore: suspend (String) -> String,
        onProgress: (String, Long, Long?) -> Unit,
        ): AndroidDownloadedSnapshot {
            downloads++
            onProgress("decoding", 0, null)
            assertEquals("access", accessToken)
            return AndroidDownloadedSnapshot("{}", "/tmp/download")
        }
        override fun persistSelectedGraphId(graphId: String) = Unit
        override fun deleteTemporaryFile(path: String) { cleaned += path }
    }

    @Test
    fun `resync downloads a fresh snapshot without blocking an open graph`() = runBlocking {
        val storage = Storage()
        val requests = mutableListOf<JSONObject>()
        val progress = mutableListOf<AndroidGraphProgress?>()
        val lifecycle = AndroidGraphLifecycle(
            callCore = { request ->
                requests += JSONObject(request).getJSONObject("params")
                """{"ok":true,"result":{"selectedGraphId":"plain-1","graphs":[],"graphBootstrap":{"kind":"download","isEncrypted":false,"generation":3}}}"""
            }, effects = storage, accessTokenProvider = { "access" }, onProgress = { progress += it },
        )
        val result = lifecycle.openGraphForResync("plain-1")
        assertTrue(progress.isEmpty())
        assertTrue(result.succeeded)
        assertEquals(1, storage.downloads)
        assertTrue(requests.none { it.optString("action") in listOf("selectGraph", "openGraph") })
        val imported = requests.single { it.optString("action") == "importSnapshot" }
        val payload = JSONObject(imported.getString("payload"))
        assertTrue(payload.getBoolean("forceSnapshot"))
        assertEquals(3, payload.getInt("generation"))
        assertEquals(listOf("/tmp/download"), storage.cleaned)
    }

    @Test
    fun `deferred snapshot import cleans its download and preserves the core failure`() = runBlocking {
        val storage = Storage()
        val progress = mutableListOf<AndroidGraphProgress?>()
        val lifecycle = AndroidGraphLifecycle(
            callCore = { request ->
                if (JSONObject(request).getJSONObject("params").optString("action") == "importSnapshot")
                    """{"ok":false,"error":{"code":"snapshot_deferred","message":"Still editing"}}"""
                else """{"ok":true,"result":{"selectedGraphId":"plain-1","graphs":[],"graphBootstrap":{"kind":"download","isEncrypted":false,"generation":3}}}"""
            }, effects = storage, accessTokenProvider = { "access" }, onProgress = { progress += it },
        )
        val result = lifecycle.openGraphForResync("plain-1")
        assertTrue(progress.isEmpty())
        assertEquals(false, result.succeeded)
        assertEquals("snapshot_deferred\nStill editing", result.message)
        assertEquals(listOf("/tmp/download"), storage.cleaned)
    }

    @Test
    fun `opening a graph explicitly still reports snapshot progress`() = runBlocking {
        val progress = mutableListOf<AndroidGraphProgress?>()
        val lifecycle = AndroidGraphLifecycle(
            callCore = {
                """{"ok":true,"result":{"selectedGraphId":"plain-1","graphs":[],"graphBootstrap":{"kind":"download","isEncrypted":false,"generation":3}}}"""
            }, effects = Storage(), accessTokenProvider = { "access" }, onProgress = { progress += it },
        )
        val opened = lifecycle.execute(NativeEffect(1, "open-graph", "plain-1"))
        assertTrue(opened.succeeded)
        assertEquals(listOf("downloading", "decoding", "importing", "opening", null), progress.map { it?.phase })
    }
}
