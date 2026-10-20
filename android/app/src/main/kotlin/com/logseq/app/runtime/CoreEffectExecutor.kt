package com.logseq.app.runtime

import java.util.UUID
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
    private val nowMilliseconds: () -> Long = { System.currentTimeMillis() },
    private val newUuid: () -> String = ::newCoreUuid,
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
                ?: return NativeEffectResolution.Discard(
                    succeeded = false,
                    message = "Unsupported LG effect: ${effect.kind}",
                )
            val response = callCore(request.toString())
            resolution(response)
        } catch (error: Throwable) {
            NativeEffectResolution.Failure(error.toString())
        }
    }

    private fun request(effect: NativeEffect): JSONObject? {
        val action: String
        var payload: String? = null
        when (effect.kind) {
            "send-asset" -> {
                action = "addAsset"
                payload = effect.text
            }
            "send-capture" -> {
                action = "send"
                payload = JSONObject()
                    .put("text", effect.text)
                    .put("uuid", newUuid())
                    .put("now", nowMilliseconds())
                    .toString()
            }
            "send-task" -> {
                action = "sendTask"
                payload = JSONObject()
                    .put("text", effect.text)
                    .put("uuid", newUuid())
                    .put("now", nowMilliseconds())
                    .put("status", metadataObject(effect, "task status"))
                    .toString()
            }
            "load-page-references" -> {
                action = "loadPageReferences"
                payload = effect.text
            }
            "hydrate-outliner-rows" -> {
                action = "hydrateOutlinerRows"
                payload = effect.text
            }
            "search-nodes" -> {
                action = "searchNodes"
                payload = effect.text
            }
            "open-node", "open-search-result" -> {
                action = "openNode"
                payload = JSONObject().put("uuid", effect.text)
                    .put("reveal", effect.kind == "open-search-result").toString()
            }
            "close-node" -> action = "closeNode"
            "select-sidebar-page" -> {
                action = "selectPage"
                payload = effect.text
            }
            "clear-selected-page" -> action = "clearSelectedPage"
            "load-older-journals" -> action = "loadOlderJournals"
            "set-page-favorite" -> {
                action = "setPageFavorite"
                payload = JSONObject()
                    .put("pageUuid", effect.text)
                    .put("favorite", effect.value == 1L)
                    .put("operationId", newUuid())
                    .put("now", nowMilliseconds())
                    .toString()
            }
            "delete-page" -> {
                action = "deletePage"
                payload = JSONObject()
                    .put("pageUuid", effect.text)
                    .put("operationId", newUuid())
                    .put("now", nowMilliseconds())
                    .toString()
            }
            "load-flashcards" -> {
                action = "loadFlashcards"
                payload = nowMilliseconds().toString()
            }
            "review-flashcard" -> {
                action = "reviewFlashcard"
                payload = JSONObject()
                    .put("uuid", requiredUuid(effect))
                    .put("rating", effect.text)
                    .put("now", nowMilliseconds())
                    .put("operationId", newUuid())
                    .toString()
            }
            "refresh-graphs" -> action = "refresh"
            "tap-outliner-block" -> return outlinerRequest(
                JSONObject().put("type", "tapBlock").put("uuid", effect.text)
            )
            "toggle-outliner-collapsed" -> return outlinerRequest(
                JSONObject().put("type", "toggleCollapsed").put("uuid", effect.text)
            )
            "long-press-outliner-block" -> return outlinerRequest(
                JSONObject().put("type", "longPressBlock").put("uuid", effect.text)
            )
            "add-root-block" -> return outlinerRequest(
                JSONObject().put("type", "addRootBlock").put("uuid", effect.text)
            )
            "drop-outliner-blocks" -> {
                val placement = effect.metadata
                    ?: throw IllegalArgumentException(
                        "The outliner drop effect is missing its placement"
                    )
                return outlinerRequest(
                    JSONObject()
                        .put("type", "dropBlocks")
                        .put("targetUuid", effect.text)
                        .put("placement", placement)
                )
            }
            "set-outliner-task-status" -> {
                val status = metadataObject(effect, "task status")
                return outlinerRequest(
                    JSONObject()
                        .put("type", "setTaskStatus")
                        .put("uuid", effect.text)
                        .put("statusIdent", status.optString("ident"))
                        .put("statusUuid", status.optString("uuid"))
                )
            }
            "outliner-toolbar" -> return outlinerRequest(
                JSONObject().put("type", "toolbar").put("action", effect.text)
            )
            "choose-outliner-autocomplete" -> return outlinerRequest(
                JSONObject().put("type", "chooseAutocomplete").put("value", effect.text)
            )
            "save-outliner-editing" -> return outlinerRequest(
                JSONObject().put("type", "saveEditing")
            )
            "cancel-outliner-editing" -> return outlinerRequest(
                JSONObject().put("type", "cancelEditing")
            )
            "change-outliner-text" -> return outlinerRequest(
                JSONObject()
                    .put("type", "textChanged")
                    .put("uuid", requiredUuid(effect))
                    .put("title", effect.text)
                    .put("caretUTF16Offset", requiredValue(effect))
            )
            "return-outliner-editor" -> return outlinerRequest(
                JSONObject()
                    .put("type", "returnPressed")
                    .put("uuid", requiredUuid(effect))
                    .put("title", effect.text)
                    .put("caretUTF16Offset", requiredValue(effect))
            )
            "backspace-outliner-editor" -> return outlinerRequest(
                JSONObject()
                    .put("type", "backspacePressed")
                    .put("uuid", requiredUuid(effect))
                    .put("title", effect.text)
                    .put("selectionLength", requiredValue(effect))
            )
            "move-outliner-caret" -> return outlinerRequest(
                JSONObject()
                    .put("type", "caretMoved")
                    .put("uuid", requiredUuid(effect))
                    .put("caretUTF16Offset", requiredValue(effect))
            )
            else -> return null
        }
        return rpcRequest(action, payload)
    }

    private fun outlinerRequest(event: JSONObject): JSONObject =
        rpcRequest("outlinerEvent", event.toString())

    private fun rpcRequest(action: String, payload: String?): JSONObject {
        val params = JSONObject().put("action", action)
        if (payload != null) params.put("payload", payload)
        return JSONObject()
            .put("apiVersion", 1)
            .put("method", "dispatch")
            .put("params", params)
    }

    private fun metadataObject(effect: NativeEffect, label: String): JSONObject {
        val metadata = effect.metadata
            ?: throw IllegalArgumentException(
                "The ${effect.kind} effect is missing its $label"
            )
        return try {
            JSONObject(metadata)
        } catch (error: Throwable) {
            throw IllegalArgumentException(
                "The ${effect.kind} $label must be an object",
                error,
            )
        }
    }

    private fun requiredUuid(effect: NativeEffect): String = effect.uuid
        ?: throw IllegalArgumentException(
            "The ${effect.kind} effect is missing its UUID"
        )

    private fun requiredValue(effect: NativeEffect): Long = effect.value
        ?: throw IllegalArgumentException(
            "The ${effect.kind} effect is missing its integer value"
        )

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

// Same shape as the Dart counterpart: microsecond timestamp hex twice.
internal fun newCoreUuid(): String {
    val timestamp = (System.currentTimeMillis() * 1_000).toString(16)
    return "$timestamp-${timestamp.padStart(32, '0').substring(0, 32)}"
}
