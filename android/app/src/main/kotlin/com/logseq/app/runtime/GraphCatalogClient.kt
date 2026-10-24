package com.logseq.app.runtime

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

// Network waits happen between short core calls, leaving native UI events available.
internal class GraphCatalogClient(private val callCore: suspend (String) -> String) {
    suspend fun refresh(): String {
        val prepared = JSONObject(call("prepareGraphCatalog", JSONObject()))
        if (!prepared.optBoolean("ok")) return prepared.toString()
        val result = prepared.getJSONObject("result")
        val request = result.optJSONObject("request") ?: return prepared.toString()
        val response = withContext(Dispatchers.IO) {
            AndroidPendingSyncTransport.send(AndroidPendingSyncRequest.fromJson(request))
        }
        return call("completeGraphCatalog", JSONObject()
            .put("baseUrl", result.getString("baseUrl")).put("token", result.getString("token"))
            .put("status", response.status ?: 0).put("body", response.body ?: "")
            .put("error", response.error ?: ""))
    }

    private suspend fun call(action: String, payload: JSONObject) = callCore(JSONObject()
        .put("apiVersion", 1).put("method", "dispatch").put("params", JSONObject()
            .put("action", action).put("payload", payload.toString())).toString())
}
