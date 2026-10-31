package com.logseq.app.runtime

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeEffectDrainTest {
    @Test fun failedDrainDoesNotStrandLaterEffects() = runBlocking {
        val pending = ArrayDeque(listOf(
            """{"effect":{"id":1,"kind":"test","text":""},"patch":""}""",
            """{"effect":{"id":2,"kind":"test","text":""},"patch":""}""",
        ))
        val runtime = object : NativeEffectRuntime {
            override fun takeEffect() = pending.removeFirstOrNull().orEmpty()
            override fun resolveEffect(id: Long, succeeded: Boolean, message: String) = ""
            override fun applySnapshot(response: String) = ""
            override fun applyHostUpdate(kind: String, payload: String) = ""
        }
        val delivered = mutableListOf<Long>()
        val drain = NativeEffectDrain(runtime, { effect ->
            check(effect.id != 1L) { "Execution failed" }
            delivered.add(effect.id)
            NativeEffectResolution.Discard()
        }, {})
        assertTrue(runCatching { drain.drain(this) }.isFailure)

        val retry = async(start = CoroutineStart.UNDISPATCHED) { drain.drain(this@runBlocking) }
        val finished = retry.isCompleted
        if (!finished) retry.cancelAndJoin()
        assertTrue("Later effects must not wait on a failed drain", finished)
        retry.await()
        assertEquals(listOf(2L), delivered)
    }
}
