package com.logseq.app.runtime

import org.json.JSONObject

// Kotlin port of the former native_effect_drain.dart.
//
// The OCaml core queues host effects; takeEffect() dequeues one as
// {effect:{id,kind,text,uuid?,value?,metadata?}, patch}. The drain loop
// applies the patch, executes the effect, and feeds the resolution back:
//   coreResponse → applySnapshot(response)
//   hostUpdate   → applyHostUpdate(kind, payload)
//   discard      → resolveEffect only
// Deadlines and save decisions are supplied by the shared core.
internal interface NativeEffectRuntime {
    fun takeEffect(): String
    fun resolveEffect(id: Long, succeeded: Boolean, message: String): String
    fun applySnapshot(response: String): String
    fun applyHostUpdate(kind: String, payload: String): String
}

internal data class NativeEffect(
    val id: Long,
    val kind: String,
    val text: String,
    val uuid: String? = null,
    val value: Long? = null,
    val metadata: String? = null,
)

internal enum class NativeEffectOutputKind { CoreResponse, HostUpdate, Discard }

internal sealed class NativeEffectResolution(
    val succeeded: Boolean,
    val message: String,
) {
    class CoreResponse(val response: String) : NativeEffectResolution(true, response)
    class HostUpdate(val kind: String, val payload: String) : NativeEffectResolution(true, payload)
    class Discard(succeeded: Boolean = true, message: String = "") :
        NativeEffectResolution(succeeded, message)
    class Failure(message: String) : NativeEffectResolution(false, message)
}

internal fun interface NativeEffectExecutor {
    suspend fun execute(effect: NativeEffect): NativeEffectResolution
}

internal class NativeEffectDrain(
    private val runtime: NativeEffectRuntime,
    private val execute: NativeEffectExecutor,
    private val applyPatch: (String) -> Unit,
    private val onError: (Throwable) -> Unit = {},
    private val trace: (String) -> Unit = {},
    private val afterCoreResponseApplied: (suspend (String) -> Unit)? = null,
) {
    @Volatile private var disposed = false

    private var activeDrain: kotlinx.coroutines.Job? = null
    private var queryWake: kotlinx.coroutines.CompletableDeferred<Unit>? = null

    // Reentrant: concurrent drain() calls join the in-flight loop.
    suspend fun drain(scope: kotlinx.coroutines.CoroutineScope) {
        if (disposed) return
        val active = activeDrain
        if (active != null && active.isActive) {
            queryWake?.complete(Unit)
            active.join()
            return
        }
        val job = kotlinx.coroutines.Job(scope.coroutineContext[kotlinx.coroutines.Job])
        activeDrain = job
        try {
            kotlinx.coroutines.withContext(job) { run() }
        } finally {
            job.complete()
            if (activeDrain === job) activeDrain = null
        }
    }

    private suspend fun run() {
        while (!disposed) {
            val encoded = runtime.takeEffect()
            if (encoded.isEmpty()) {
                return
            }

            val waitMillis = runCatching { JSONObject(encoded).optLong("waitMs", 0) }.getOrDefault(0)
            if (waitMillis > 0) {
                val wake = kotlinx.coroutines.CompletableDeferred<Unit>()
                queryWake = wake
                kotlinx.coroutines.withTimeoutOrNull(waitMillis.coerceIn(1, 200)) { wake.await() }
                queryWake = null
                continue
            }

            val dispatch = try {
                EffectDispatch.decode(encoded)
            } catch (error: Throwable) {
                onError(error)
                return
            }

            apply(dispatch.patch, "dispatch kind=${dispatch.effect.kind}")
            trace("start id=${dispatch.effect.id} kind=${dispatch.effect.kind}")
            val resolution = execute.execute(dispatch.effect)
            trace(
                "finish id=${dispatch.effect.id} kind=${dispatch.effect.kind} " +
                    "succeeded=${resolution.succeeded}"
            )
            if (resolution.succeeded) {
                when (resolution) {
                    is NativeEffectResolution.CoreResponse -> {
                        apply(runtime.applySnapshot(resolution.response), "applySnapshot")
                        afterCoreResponseApplied?.invoke(resolution.response)
                    }
                    is NativeEffectResolution.HostUpdate -> apply(
                        runtime.applyHostUpdate(resolution.kind, resolution.payload),
                        "applyHostUpdate kind=${resolution.kind}",
                    )
                    else -> Unit
                }
            }
            apply(
                runtime.resolveEffect(
                    dispatch.effect.id,
                    resolution.succeeded,
                    resolution.message,
                ),
                "resolveEffect id=${dispatch.effect.id} succeeded=${resolution.succeeded}",
            )
        }
    }

    fun dispose() {
        disposed = true
        activeDrain?.cancel()
        queryWake?.complete(Unit)
        queryWake = null
    }

    private fun apply(patch: String, source: String) {
        if (patch.isNotEmpty()) {
            trace("applying patch from $source chars=${patch.length}")
            applyPatch(patch)
            trace("applied patch from $source")
        } else {
            trace("empty patch from $source")
        }
    }
}

internal class EffectDispatch private constructor(
    val effect: NativeEffect,
    val patch: String,
) {
    companion object {
        fun decode(encoded: String): EffectDispatch {
            val decoded = JSONObject(encoded)
            val effect = decoded.optJSONObject("effect")
                ?: throw IllegalArgumentException("Effect dispatch is missing effect")
            val patch = decoded.optString("patch")
            if (!decoded.has("patch") || patch == null) {
                throw IllegalArgumentException("Effect dispatch is missing patch")
            }
            if (!effect.has("id") || !effect.has("kind") || !effect.has("text")) {
                throw IllegalArgumentException("Effect contains invalid required values")
            }
            return EffectDispatch(
                effect = NativeEffect(
                    id = effect.getLong("id"),
                    kind = effect.getString("kind"),
                    text = effect.getString("text"),
                    uuid = effect.optString("uuid").takeIf(String::isNotEmpty),
                    value = if (effect.has("value")) effect.getLong("value") else null,
                    metadata = effect.optString("metadata").takeIf(String::isNotEmpty),
                ),
                patch = patch,
            )
        }
    }
}
