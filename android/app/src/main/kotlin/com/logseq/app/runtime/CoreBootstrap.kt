package com.logseq.app.runtime

import org.json.JSONObject
import com.logseq.app.AndroidGraphLocalStorage
import java.io.File

// Kotlin port of the former core_bootstrap.dart: restore the core's
// persisted state — open the catalog database, dispatch configure with
// baseUrl/graphId/token, then open the selected local graph when its
// encryption key is available.
internal data class CoreStartupState(
    val databasePath: String,
    val graphsDirectory: String,
    val baseUrl: String,
    val selectedGraphId: String,
    val localGraphIds: List<String>,
    val accessToken: String,
)

internal data class CoreBootstrapResult(
    val catalogResponse: String,
    val graphResponse: String?,
    val localGraphIds: List<String>,
)

internal class CoreBootstrap(
    private val callCore: suspend (String) -> String,
    private val trace: (String) -> Unit = {},
) {
    suspend fun restore(state: CoreStartupState): CoreBootstrapResult {
        val catalogResponse = call(
            operation = "open catalog",
            request = request(method = "open", path = state.databasePath),
        )
        val catalog = successfulResult(catalogResponse, operation = "open catalog")
        val configured = successfulResult(
            call(
                operation = "configure graph",
                request = request(
                    method = "dispatch",
                    action = "configure",
                    payload = JSONObject()
                        .put("baseUrl", state.baseUrl)
                        .put("graphId", state.selectedGraphId)
                        .put("token", state.accessToken)
                        .toString(),
                ),
            ),
            operation = "configure graph",
        )

        var graphResponse: String? = null
        val encrypted = graphIsEncrypted(catalog, state.selectedGraphId)
        if (state.selectedGraphId.isNotEmpty() &&
            state.localGraphIds.contains(state.selectedGraphId) &&
            (!encrypted || configured.optBoolean("isGraphUnlocked"))
        ) {
            val graphs = catalog.optJSONArray("graphs")
            val name = (0 until (graphs?.length() ?: 0)).asSequence()
                .mapNotNull { graphs?.optJSONObject(it) }.firstOrNull { it.optString("id") == state.selectedGraphId }
                ?.optString("name").orEmpty().ifBlank { "Graph" }
            val directory = AndroidGraphLocalStorage.prepare(
                File(state.graphsDirectory), state.selectedGraphId, name).path
            graphResponse = call(
                operation = "open local graph",
                request = request(
                    method = "dispatch",
                    action = "openGraph",
                    payload = JSONObject()
                        .put("graphId", state.selectedGraphId)
                        .put("activePath", "$directory/graph.sqlite")
                        .put("checkpointPath", "$directory/sync.checkpoint")
                        .put("isEncrypted", encrypted)
                        .toString(),
                ),
            )
            successfulResult(graphResponse, operation = "open local graph")
        }

        return CoreBootstrapResult(
            catalogResponse = catalogResponse,
            graphResponse = graphResponse,
            localGraphIds = state.localGraphIds,
        )
    }

    private suspend fun call(operation: String, request: String): String {
        trace("$operation started")
        val started = System.nanoTime()
        try {
            return callCore(request)
        } finally {
            trace("$operation completed durationMs=${(System.nanoTime() - started) / 1_000_000}")
        }
    }

    private fun graphIsEncrypted(catalog: JSONObject, graphId: String): Boolean {
        val graphs = catalog.optJSONArray("graphs") ?: return false
        for (index in 0 until graphs.length()) {
            val graph = graphs.optJSONObject(index) ?: continue
            if (graph.optString("id") == graphId) return graph.optBoolean("isEncrypted")
        }
        return false
    }

    private fun successfulResult(encoded: String, operation: String): JSONObject {
        val response = try {
            JSONObject(encoded)
        } catch (error: Throwable) {
            throw IllegalStateException(
                "Could not $operation: core response is not an object",
                error,
            )
        }
        if (!response.optBoolean("ok")) {
            val message = response.optJSONObject("error")?.optString("message")
            throw IllegalStateException(
                "Could not $operation: ${message ?: "unknown core error"}"
            )
        }
        return response.optJSONObject("result") ?: JSONObject()
    }

    private fun request(
        method: String,
        action: String? = null,
        payload: String? = null,
        path: String? = null,
    ): String {
        val params = JSONObject()
        if (action != null) params.put("action", action)
        if (payload != null) params.put("payload", payload)
        if (path != null) params.put("path", path)
        return JSONObject()
            .put("apiVersion", 1)
            .put("method", method)
            .put("params", params)
            .toString()
    }
}
