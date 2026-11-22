package com.logseq.logseq.runtime

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.util.Log
import com.logseq.logseq.AndroidPlatformServices
import com.logseq.logseq.AndroidSyncJobService
import com.logseq.logseq.AndroidWidgetContent
import com.logseq.logseq.CognitoAuthProvider
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import com.logseq.logseq.AndroidE2EECrypto
import com.logseq.logseq.AndroidHttpTransport
import com.logseq.logseq.widgetRequest
import org.json.JSONObject

internal enum class BackgroundSyncResult { Success, Skipped, Retry }

// One native session owns the process. A live UI supplies its own sync operation;
// a cold background job acquires the same lease before opening any database.
internal object NativeCoreSession {
    val gate = Mutex()
    @Volatile var syncActive: (suspend () -> BackgroundSyncResult)? = null
    @Volatile var updateActiveWidgetTask: (suspend (WidgetTaskStatusChange) -> Boolean)? = null
    @Volatile var refreshActiveRandomWidget: (suspend () -> Unit)? = null
    val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
}

internal data class WidgetTaskStatusChange(
    val graphId: String,
    val uuid: String,
    val expectedStatusUuid: String,
    val statusUuid: String,
) {
    fun request(): String = widgetRequest("setWidgetTaskStatus", JSONObject()
        .put("graphId", graphId)
        .put("uuid", uuid)
        .put("expectedStatusUuid", expectedStatusUuid)
        .put("statusUuid", statusUuid))
}

internal object AndroidBackgroundSync {
    const val jobId = 0x1001
    private const val widgetSyncJobId = 0x1002

    fun schedule(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler.getPendingJob(jobId) != null) return
        val job = JobInfo.Builder(jobId, ComponentName(context, AndroidSyncJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(15 * 60 * 1000L, 5 * 60 * 1000L)
            .setPersisted(true)
            .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build()
        if (scheduler.schedule(job) != JobScheduler.RESULT_SUCCESS) Log.w("BackgroundSync", "Could not schedule background sync")
    }

    suspend fun updateWidgetTaskStatus(context: Context, change: WidgetTaskStatusChange): Boolean {
        return try {
            withTimeoutOrNull(8_000) {
                NativeCoreSession.updateActiveWidgetTask?.let { return@withTimeoutOrNull it(change) }
                val owner = Any()
                NativeCoreSession.gate.lock(owner)
                try {
                    val saved = updateStoredWidgetTask(context, change)
                    if (saved) scheduleWidgetSync(context)
                    saved
                } finally {
                    NativeCoreSession.gate.unlock(owner)
                }
            } ?: false
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w("LogseqWidgets", "Could not update widget task status", error)
            false
        }
    }

    suspend fun refreshRandomWidget(context: Context) {
        try {
            withTimeoutOrNull(8_000) {
                NativeCoreSession.refreshActiveRandomWidget?.let {
                    it()
                    return@withTimeoutOrNull
                }
                val owner = Any()
                NativeCoreSession.gate.lock(owner)
                try {
                    val bridge = LogseqNativeBridge()
                    if (restoreStoredWidgetGraph(context, bridge)) {
                        AndroidWidgetContent.refresh(context, bridge::callCore, resampleRandom = true)
                    }
                } finally {
                    NativeCoreSession.gate.unlock(owner)
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w("LogseqWidgets", "Could not refresh random blocks", error)
        }
    }

    private suspend fun updateStoredWidgetTask(context: Context, change: WidgetTaskStatusChange): Boolean {
        val bridge = LogseqNativeBridge()
        if (!restoreStoredWidgetGraph(context, bridge, change.graphId)) return false
        val saved = JSONObject(bridge.callCore(change.request())).optBoolean("ok")
        AndroidWidgetContent.refresh(context, bridge::callCore)
        return saved
    }

    private suspend fun restoreStoredWidgetGraph(
        context: Context,
        bridge: LogseqNativeBridge,
        expectedGraphId: String? = null,
    ): Boolean {
        val authentication = CognitoAuthProvider(context)
        if (!authentication.hasStoredSession()) return false
        val storage = AndroidStorageState.fromPlatformMap(AndroidPlatformServices(context).loadStorageState())
        if (storage.selectedGraphId !in storage.localGraphIds ||
            (expectedGraphId != null && storage.selectedGraphId != expectedGraphId)
        ) return false
        AndroidE2EECrypto.initialize(context.applicationContext)
        val restored = CoreBootstrap(bridge::callCore).restore(CoreStartupState(
            storage.databasePath, storage.graphsDirectory, storage.baseUrl,
            storage.selectedGraphId, storage.localGraphIds, accessToken = "",
        ))
        return restored.graphResponse != null
    }

    private fun scheduleWidgetSync(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler.getPendingJob(widgetSyncJobId) != null) return
        val job = JobInfo.Builder(widgetSyncJobId, ComponentName(context, AndroidSyncJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build()
        if (scheduler.schedule(job) != JobScheduler.RESULT_SUCCESS) {
            Log.w("BackgroundSync", "Could not schedule widget sync")
        }
    }

    suspend fun run(context: Context): BackgroundSyncResult = try {
        withTimeout(90_000) {
            NativeCoreSession.syncActive?.let { return@withTimeout it() }
            val owner = Any()
            if (!NativeCoreSession.gate.tryLock(owner)) return@withTimeout BackgroundSyncResult.Retry
            try { syncStoredGraph(context) }
            finally { NativeCoreSession.gate.unlock(owner) }
        }
    } catch (timeout: TimeoutCancellationException) {
        currentCoroutineContext().ensureActive()
        BackgroundSyncResult.Retry
    } catch (cancelled: CancellationException) {
        currentCoroutineContext().ensureActive()
        BackgroundSyncResult.Retry
    } catch (error: Exception) {
        Log.w("BackgroundSync", "Background sync failed", error)
        BackgroundSyncResult.Retry
    }

    private suspend fun syncStoredGraph(context: Context): BackgroundSyncResult {
        val authentication = CognitoAuthProvider(context)
        if (!authentication.hasStoredSession()) return BackgroundSyncResult.Skipped
        val storage = AndroidStorageState.fromPlatformMap(AndroidPlatformServices(context).loadStorageState())
        if (storage.selectedGraphId.isEmpty() || storage.selectedGraphId !in storage.localGraphIds) return BackgroundSyncResult.Skipped
        val token = authentication.apiToken()?.takeIf { it.isNotBlank() } ?: return BackgroundSyncResult.Skipped
        AndroidE2EECrypto.initialize(context.applicationContext)
        AndroidHttpTransport.initialize(context.applicationContext)
        val bridge = LogseqNativeBridge()
        val restored = CoreBootstrap(bridge::callCore).restore(CoreStartupState(
            storage.databasePath, storage.graphsDirectory, storage.baseUrl,
            storage.selectedGraphId, storage.localGraphIds, token))
        if (restored.graphResponse == null) return BackgroundSyncResult.Skipped
        var lastResponse = JSONObject(restored.graphResponse)
        val job = currentCoroutineContext().job
        lateinit var pull: AndroidGraphEventsSync
        val pump = AndroidPendingSyncPump(bridge::callCore, { response ->
            lastResponse = JSONObject(response)
            check(lastResponse.optBoolean("ok")) { "The native core rejected background sync" }
        }, { !job.isActive }, sendWebSocket = { pull.sendPending(it) })
        fun pendingFailed() = lastResponse.optJSONObject("result")?.let { !it.isNull("pendingSyncError") } == true
        pull = AndroidGraphEventsSync(bridge::callCore, { response ->
            lastResponse = JSONObject(response)
        }, { pump.run() }, { !job.isActive }, stopAfterFirstPull = true)
        val result = pull.runSession(AndroidGraphEventsSync.Connection(storage.selectedGraphId, storage.baseUrl, token))
        AndroidWidgetContent.refresh(context, bridge::callCore)
        return if (result == AndroidGraphEventsSync.SessionOutcome.Completed && !pendingFailed())
            BackgroundSyncResult.Success else BackgroundSyncResult.Retry
    }
}
