package com.logseq.app.runtime

import org.json.JSONObject

// Kotlin port of the former core_effect_executor.dart.
//
// Routes each NativeEffect to its executor:
//   - platform effect kinds  → AndroidPlatformEffects
//   - graph effect kinds     → AndroidGraphLifecycle
//   - everything else        → a core `dispatch` RPC whose response is
//                              applied via applySnapshot when ok:true.
internal class CoreEffectExecutor(
    private val callCore: suspend (String) -> String,
    private val executePlatformEffect: NativeEffectExecutor,
    private val executeGraphEffect: NativeEffectExecutor,
) {
    suspend fun execute(effect: NativeEffect): NativeEffectResolution {
        if (effect.kind in platformEffectKinds) {
            return executePlatformEffect.execute(effect)
        }
        if (effect.kind in graphEffectKinds) {
            return executeGraphEffect.execute(effect)
        }
        return try {
            val request = request(effect)
            val response = callCore(request.toString())
            resolution(response)
        } catch (error: Throwable) {
            NativeEffectResolution.Failure(error.toString())
        }
    }

    private fun request(effect: NativeEffect): JSONObject {
        val payload = JSONObject().put("id", effect.id).put("kind", effect.kind).put("text", effect.text)
        effect.uuid?.let { payload.put("uuid", it) }
        effect.value?.let { payload.put("value", it) }
        effect.metadata?.let { payload.put("metadata", it) }
        return JSONObject().put("apiVersion", 1).put("method", "dispatch")
            .put("params", JSONObject().put("action", "executeEffect").put("payload", payload.toString()))
    }

    private fun resolution(response: String): NativeEffectResolution {
        val decoded = try {
            JSONObject(response)
        } catch (error: Throwable) {
            throw IllegalArgumentException(
                "The native core response must be an object",
                error,
            )
        }
        if (decoded.optBoolean("ok")) {
            return NativeEffectResolution.CoreResponse(response)
        }
        val error = decoded.optJSONObject("error")
        val code = error?.optString("code")?.takeIf(String::isNotEmpty) ?: "core_error"
        val message = error?.optString("message")?.takeIf(String::isNotEmpty)
            ?: "The OCaml core rejected the effect"
        return NativeEffectResolution.Discard(succeeded = false, message = "$code\n$message")
    }

    companion object {
        private val platformEffectKinds = setOf(
            "present-journal-calendar",
            "persist-composer-draft",
            "present-attachment",
            "present-asset",
            "present-page-share",
            "sync-now",
            "sync-pending",
            "delete-local-graph",
            "save-settings",
            "export-graph-database",
            "open-external-url",
            "refresh-runtime-log",
            "copy-runtime-log",
            "sign-in",
            "sign-out",
        )

        private val graphEffectKinds = setOf(
            "open-graph",
            "unlock-graph",
            "create-graph",
        )
    }
}
