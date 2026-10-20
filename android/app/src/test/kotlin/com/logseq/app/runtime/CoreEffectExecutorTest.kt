package com.logseq.app.runtime

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreEffectExecutorTest {
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
        assertEquals("outlinerEvent", params.getString("action"))
        assertEquals("confirmDelete", JSONObject(params.getString("payload")).getString("type"))
        assertTrue(resolution.succeeded)
    }
}
