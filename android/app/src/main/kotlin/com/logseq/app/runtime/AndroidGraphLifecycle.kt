package com.logseq.app.runtime

import org.json.JSONObject
import com.logseq.app.AndroidGraphLocalStorage
import java.io.File

internal interface AndroidGraphStorage {
    fun loadStorageState(): AndroidStorageState
    suspend fun downloadGraphSnapshot(
        baseUrl: String, graphId: String, accessToken: String, workingDirectory: String,
        callCore: suspend (String) -> String,
        onProgress: (String, Long, Long?) -> Unit = { _, _, _ -> },
    ): AndroidDownloadedSnapshot
    fun persistSelectedGraphId(graphId: String)
    fun deleteTemporaryFile(path: String)
}

// Kotlin port of the former android_graph_lifecycle.dart: openGraph /
// createGraph / unlockGraph effects, including the remote-snapshot
// download path for graphs that are not stored locally.
internal class AndroidGraphLifecycle(
    private val callCore: suspend (String) -> String,
    private val effects: AndroidGraphStorage,
    private val accessTokenProvider: suspend () -> String? = { "" },
    private val trace: (String) -> Unit = {},
    private val onProgress: (AndroidGraphProgress?) -> Unit = {},
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

    // Execute the core's snapshot recovery command without resetting editor state.
    // The core validates editing and graph ownership immediately before import.
    suspend fun openGraphForResync(graphId: String): NativeEffectResolution =
        openGraph(graphId, forceSnapshot = true)

    // The first snapshots after open ship an empty sidebar so the scan
    // stays off the launch path; this fills favorites/recent afterwards.
    suspend fun loadSidebar(): String = call("loadSidebar")

    private suspend fun openGraph(graphId: String, forceSnapshot: Boolean = false): NativeEffectResolution =
        try { openGraphWithProgress(graphId, forceSnapshot) } finally { onProgress(null) }

    private suspend fun openGraphWithProgress(graphId: String, forceSnapshot: Boolean): NativeEffectResolution {
        trace("open.start graphId=$graphId")
        val selected = if (forceSnapshot) {
            callCore("""{"apiVersion":1,"method":"snapshot","params":{}}""")
        } else call("selectGraph", payload = graphId)
        failure(selected)?.let { return it }
        trace("select.complete graphId=$graphId")

        val state = effects.loadStorageState()
        val catalog = decodedResponse(selected).optJSONObject("result")?.optJSONArray("graphs")
        val graphName = (0 until (catalog?.length() ?: 0)).asSequence()
            .mapNotNull { catalog?.optJSONObject(it) }.firstOrNull { it.optString("id") == graphId }
            ?.optString("name").orEmpty().ifBlank { "Graph" }
        val directory = AndroidGraphLocalStorage.prepare(File(state.graphsDirectory), graphId, graphName).path
        val bootstrap = call("bootstrapGraph", JSONObject().put("graphId", graphId)
            .put("activePath", "$directory/graph.sqlite").put("checkpointPath", "$directory/sync.checkpoint")
            .put("forceSnapshot", forceSnapshot).toString())
        failure(bootstrap)?.let { return it }
        val plan = decodedResponse(bootstrap).getJSONObject("result").getJSONObject("graphBootstrap")
        val isEncrypted = plan.getBoolean("isEncrypted")
        val opened: String
        if (plan.getString("kind") != "download") {
            opened = bootstrap
        } else {
            onProgress(AndroidGraphProgress(graphId, graphName, "downloading"))
            val token = accessTokenProvider() ?: ""
            trace("snapshot.download.start graphId=$graphId baseUrl=${state.baseUrl}")
            val artifact = effects.downloadGraphSnapshot(
                baseUrl = state.baseUrl,
                graphId = graphId,
                accessToken = token,
                workingDirectory = directory,
                callCore = callCore,
                onProgress = { phase, done, total ->
                    onProgress(AndroidGraphProgress(graphId, graphName, phase, done, total))
                },
            )
            trace("snapshot.download.complete graphId=$graphId path=${artifact.filePath}")
            try {
                trace("snapshot.import.start graphId=$graphId")
                onProgress(AndroidGraphProgress(graphId, graphName, "importing"))
                opened = call(
                    "importSnapshot",
                    payload = JSONObject()
                        .put("graphId", graphId)
                        .put("activePath", "$directory/graph.sqlite")
                        .put("checkpointPath", "$directory/sync.checkpoint")
                        .put("metadataBody", artifact.metadataBody)
                        .put("downloadPath", artifact.filePath)
                        .put("forceSnapshot", forceSnapshot)
                        .put("isEncrypted", isEncrypted)
                        .toString(),
                )
                trace("snapshot.import.complete graphId=$graphId")
                if (decodedResponse(opened).optBoolean("ok"))
                    onProgress(AndroidGraphProgress(graphId, graphName, "opening"))
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

    private fun decodedResponse(response: String): JSONObject = try {
        JSONObject(response)
    } catch (error: Throwable) {
        throw IllegalArgumentException("The native core response must be an object", error)
    }
}
