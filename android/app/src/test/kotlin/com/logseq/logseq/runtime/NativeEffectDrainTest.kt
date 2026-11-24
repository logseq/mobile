package com.logseq.logseq.runtime

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
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
            override suspend fun takeEffect() = pending.removeFirstOrNull().orEmpty()
            override suspend fun resolveEffect(id: Long, succeeded: Boolean, message: String) = ""
            override suspend fun applySnapshot(response: String) = ""
            override suspend fun applyHostUpdate(kind: String, payload: String) = ""
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

    @Test fun requestDuringEmptyTakeIsNotStranded() = runBlocking {
        val pending = ArrayDeque<String>()
        lateinit var drain: NativeEffectDrain
        var takes = 0
        val runtime = object : NativeEffectRuntime {
            override suspend fun takeEffect(): String {
                takes++
                if (takes == 1) {
                    // An event queues an effect after this take already read the queue.
                    pending.add("""{"effect":{"id":3,"kind":"test","text":""},"patch":""}""")
                    launch { drain.drain(this@runBlocking) }
                    yield()
                    return ""
                }
                return pending.removeFirstOrNull().orEmpty()
            }
            override suspend fun resolveEffect(id: Long, succeeded: Boolean, message: String) = ""
            override suspend fun applySnapshot(response: String) = ""
            override suspend fun applyHostUpdate(kind: String, payload: String) = ""
        }
        val delivered = mutableListOf<Long>()
        drain = NativeEffectDrain(runtime, { effect ->
            delivered.add(effect.id)
            NativeEffectResolution.Discard()
        }, {})
        drain.drain(this)
        assertEquals(listOf(3L), delivered)
    }
}
