package com.logseq.app.runtime

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.util.Log
import com.logseq.app.AndroidPlatformServices
import com.logseq.app.AndroidSyncJobService
import com.logseq.app.CognitoAuthProvider
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import logseq.app.AndroidE2EECrypto
import logseq.app.AndroidHttpTransport
import org.json.JSONObject

internal enum class BackgroundSyncResult { Success, Skipped, Retry }

// One native session owns the process. A live UI supplies its own sync operation;
// a cold background job acquires the same lease before opening any database.
internal object NativeCoreSession {
    val gate = Mutex()
    @Volatile var syncActive: (suspend () -> BackgroundSyncResult)? = null
    val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
}

internal object AndroidBackgroundSync {
    const val jobId = 0x1001

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
        val pump = AndroidPendingSyncPump(bridge::callCore, { response ->
            lastResponse = JSONObject(response)
            check(lastResponse.optBoolean("ok")) { "The native core rejected background sync" }
        }, { !job.isActive })
        fun pendingFailed() = lastResponse.optJSONObject("result")?.let { !it.isNull("pendingSyncError") } == true
        pump.run()
        if (pendingFailed()) return BackgroundSyncResult.Retry
        val pull = AndroidGraphEventsSync(bridge::callCore, { response ->
            lastResponse = JSONObject(response)
        }, { pump.run() }, { !job.isActive }, stopAfterFirstPull = true)
        val result = pull.runSession(AndroidGraphEventsSync.Connection(storage.selectedGraphId, storage.baseUrl, token))
        return if (result == AndroidGraphEventsSync.SessionOutcome.Completed && !pendingFailed())
            BackgroundSyncResult.Success else BackgroundSyncResult.Retry
    }
}
