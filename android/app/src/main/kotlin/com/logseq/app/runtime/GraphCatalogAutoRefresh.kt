package com.logseq.app.runtime

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

// Kotlin port of the former graph_catalog_auto_refresh.dart +
// graph_catalog_polling_policy.dart.
internal fun shouldPollGraphCatalog(
    authenticated: Boolean,
    hasOpenGraph: Boolean,
    foreground: Boolean,
): Boolean = authenticated && !hasOpenGraph && foreground

internal class GraphCatalogAutoRefresh(
    private val scope: CoroutineScope,
    private val callCore: suspend (String) -> String,
    private val applyCoreResponse: suspend (String) -> Unit,
    private val trace: (String) -> Unit = {},
) {
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private var periodicTask: ScheduledFuture<*>? = null
    private var activeRefresh: Job? = null
    private var catalogFingerprint: String? = null

    fun rememberCatalog(response: String) {
        catalogFingerprint = fingerprint(response)
    }

    fun startPeriodic(intervalMillis: Long = 15_000) {
        if (periodicTask != null) return
        trace("periodic.start intervalMs=$intervalMillis")
        periodicTask = scheduler.scheduleWithFixedDelay(
            { scope.launch { runCatching { refresh() } } },
            intervalMillis,
            intervalMillis,
            TimeUnit.MILLISECONDS,
        )
    }

    fun stopPeriodic() {
        periodicTask?.cancel(false)
        periodicTask = null
        trace("periodic.stop")
    }

    suspend fun refresh(): Boolean {
        activeRefresh?.let {
            it.join()
            return true
        }
        val job = scope.launch {
            run()
        }
        activeRefresh = job
        job.join()
        activeRefresh = null
        return lastRefreshResult
    }

    @Volatile private var lastRefreshResult: Boolean = false

    private suspend fun run() {
        trace("refresh.start")
        val response = GraphCatalogClient(callCore).refresh()
        val decoded = try {
            JSONObject(response)
        } catch (_: Throwable) {
            null
        }
        if (decoded == null || !decoded.optBoolean("ok")) {
            val error = decoded?.optJSONObject("error")
            trace(
                "refresh.rejected code=${error?.optString("code") ?: "unknown"} " +
                    "message=${error?.optString("message") ?: "Unknown core response"}"
            )
            lastRefreshResult = false
            return
        }
        val fingerprint = fingerprintFromEnvelope(decoded)
        if (fingerprint != null && fingerprint == catalogFingerprint) {
            trace("refresh.unchanged")
            lastRefreshResult = true
            return
        }
        applyCoreResponse(response)
        catalogFingerprint = fingerprint
        trace("refresh.complete")
        lastRefreshResult = true
    }

    private fun fingerprint(response: String): String? = try {
        fingerprintFromEnvelope(JSONObject(response))
    } catch (_: Throwable) {
        null
    }

    private fun fingerprintFromEnvelope(envelope: JSONObject): String? =
        envelope.optJSONObject("result")?.optJSONArray("graphs")?.toString()

    fun dispose() {
        stopPeriodic()
        scheduler.shutdownNow()
    }
}
