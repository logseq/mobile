package com.logseq.app.runtime

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreEffectExecutorTest {
    @Test
    fun `automatic pending sync reaches the platform upload pump`() = runBlocking {
        val kinds = mutableListOf<String>()
        val executor = CoreEffectExecutor(
            callCore = { error("Sync must use the platform transport") },
            executePlatformEffect = NativeEffectExecutor { effect ->
                kinds += effect.kind
                NativeEffectResolution.Discard(succeeded = true)
            },
            executeGraphEffect = NativeEffectExecutor { error("Unexpected graph effect") },
        )
        for (kind in listOf("sync-pending", "sync-now")) {
            assertTrue(executor.execute(NativeEffect(id = 1, kind = kind, text = "")).succeeded)
        }
        assertEquals(listOf("sync-pending", "sync-now"), kinds)
    }

    @Test
    fun `native deletion confirmation uses the shared core event`() = runBlocking {
        val requests = mutableListOf<String>()
        val executor = CoreEffectExecutor(
            callCore = { request ->
                requests += request
                """{"apiVersion":1,"ok":true,"result":null}"""
            },
            executePlatformEffect = NativeEffectExecutor { error("Unexpected platform effect") },
            executeGraphEffect = NativeEffectExecutor { error("Unexpected graph effect") },
        )
        val resolution = executor.execute(NativeEffect(id = 1, kind = "confirm-outliner-delete", text = ""))
        val params = JSONObject(requests.single()).getJSONObject("params")
        assertEquals("executeEffect", params.getString("action"))
        assertEquals("confirm-outliner-delete", JSONObject(params.getString("payload")).getString("kind"))
        assertTrue(resolution.succeeded)
    }
}
