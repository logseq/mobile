package com.logseq.app.runtime

import org.json.JSONObject

// Kotlin port of the former android_graph_lifecycle.dart: openGraph /
// createGraph / unlockGraph effects, including the remote-snapshot
// download path for graphs that are not stored locally.
internal class AndroidGraphLifecycle(
    private val callCore: suspend (String) -> String,
    private val effects: AndroidPlatformEffects,
    private val accessTokenProvider: suspend () -> String? = { "" },
    private val trace: (String) -> Unit = {},
) {
    suspend fun execute(effect: NativeEffect): NativeEffectResolution = try {
        when (effect.kind) {
            "create-graph" -> {
                val created = call(
                    "createSyncGraph",
                    payload = JSONObject()
                        .put("name", effect.text)
                        .put("isEncrypted", effect.value == 1L)
                        .put("password", effect.metadata ?: JSONObject.NULL)
                        .toString(),
                )
                failure(created)?.let { return it }
                val graphId = selectedGraphId(created)
                if (graphId.isEmpty()) {
                    return NativeEffectResolution.Discard(
                        succeeded = false,
                        message = "The created graph has no selected identifier",
                    )
                }
                openGraph(graphId)
            }
            "open-graph" -> openGraph(effect.text)
            "unlock-graph" -> resolution(call("unlockGraph", payload = effect.text))
            else -> NativeEffectResolution.Discard(
                succeeded = false,
                message = "Unsupported Android graph effect: ${effect.kind}",
            )
        }
    } catch (error: Throwable) {
        val message = "${failureCode(effect.kind)}\n$error"
        trace("effect.failed kind=${effect.kind} message=${message.replace('\n', ' ')}")
        NativeEffectResolution.Discard(succeeded = false, message = message)
    }

    private fun failureCode(kind: String): String = when (kind) {
        "create-graph" -> "graph_create_failed"
        "open-graph" -> "graph_open_failed"
        "unlock-graph" -> "graph_unlock_failed"
        else -> "graph_operation_failed"
    }

    // Re-run the open flow (select + remote snapshot re-import when needed)
    // after the sync WebSocket reports that our cursor fell off the
    // server's retained range. iOS handles this by returning from
    // runGraphEventsOnce so startSync re-bootstraps.
    suspend fun openGraphForResync(graphId: String): NativeEffectResolution =
        openGraph(graphId)

    // The first snapshots after open ship an empty sidebar so the scan
    // stays off the launch path; this fills favorites/recent afterwards.
    suspend fun loadSidebar(): String = call("loadSidebar")

    private suspend fun openGraph(graphId: String): NativeEffectResolution {
        trace("open.start graphId=$graphId")
        val selected = call("selectGraph", payload = graphId)
        failure(selected)?.let { return it }
        trace("select.complete graphId=$graphId")

        val state = effects.loadStorageState()
        val directory = "${state.graphsDirectory}/$graphId"
        val isEncrypted = graphIsEncrypted(selected, graphId)
        val isLocal = state.localGraphIds.contains(graphId)
        trace("storage.loaded graphId=$graphId local=$isLocal")
        val opened: String
        if (isLocal) {
            opened = call(
                "openGraph",
                payload = JSONObject()
                    .put("graphId", graphId)
                    .put("activePath", "$directory/graph.sqlite")
                    .put("checkpointPath", "$directory/sync.checkpoint")
                    .put("isEncrypted", isEncrypted)
                    .toString(),
            )
        } else {
            val token = accessTokenProvider() ?: ""
            trace("snapshot.download.start graphId=$graphId baseUrl=${state.baseUrl}")
            val artifact = effects.downloadGraphSnapshot(
                baseUrl = state.baseUrl,
                graphId = graphId,
                accessToken = token,
                workingDirectory = directory,
            )
            trace("snapshot.download.complete graphId=$graphId path=${artifact.filePath}")
            try {
                trace("snapshot.import.start graphId=$graphId")
                opened = call(
                    "importSnapshot",
                    payload = JSONObject()
                        .put("graphId", graphId)
                        .put("activePath", "$directory/graph.sqlite")
                        .put("checkpointPath", "$directory/sync.checkpoint")
                        .put("metadataBody", artifact.metadataBody)
                        .put("downloadPath", artifact.filePath)
                        .put("isEncrypted", isEncrypted)
                        .toString(),
                )
                trace("snapshot.import.complete graphId=$graphId")
            } finally {
                effects.deleteTemporaryFile(artifact.filePath)
            }
        }

        failure(opened)?.let { return it }
        effects.persistSelectedGraphId(graphId)
        trace("selection.persist.complete graphId=$graphId")
        trace("open.complete graphId=$graphId")
        return NativeEffectResolution.CoreResponse(opened)
    }

    private suspend fun call(action: String, payload: String? = null): String {
        val params = JSONObject().put("action", action)
        if (payload != null) params.put("payload", payload)
        return callCore(
            JSONObject()
                .put("apiVersion", 1)
                .put("method", "dispatch")
                .put("params", params)
                .toString()
        )
    }

    private fun resolution(response: String): NativeEffectResolution =
        failure(response) ?: NativeEffectResolution.CoreResponse(response)

    private fun failure(response: String): NativeEffectResolution? {
        val decoded = decodedResponse(response)
        if (decoded.optBoolean("ok")) return null
        val error = decoded.optJSONObject("error")
        val code = error?.optString("code")?.takeIf(String::isNotEmpty) ?: "core_error"
        val message = error?.optString("message")?.takeIf(String::isNotEmpty)
            ?: "The OCaml core rejected the graph operation"
        return NativeEffectResolution.Discard(succeeded = false, message = "$code\n$message")
    }

    private fun selectedGraphId(response: String): String =
        decodedResponse(response).optJSONObject("result")
            ?.optString("selectedGraphId").orEmpty()

    private fun graphIsEncrypted(response: String, graphId: String): Boolean {
        val graphs = decodedResponse(response).optJSONObject("result")
            ?.optJSONArray("graphs") ?: return false
        for (index in 0 until graphs.length()) {
            val graph = graphs.optJSONObject(index) ?: continue
            if (graph.optString("id") == graphId) return graph.optBoolean("isEncrypted")
        }
        return false
    }

    private fun decodedResponse(response: String): JSONObject = try {
        JSONObject(response)
    } catch (error: Throwable) {
        throw IllegalArgumentException("The native core response must be an object", error)
    }
}
