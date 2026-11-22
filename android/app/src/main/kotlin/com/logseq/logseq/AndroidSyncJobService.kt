package com.logseq.logseq

import android.app.job.JobParameters
import android.app.job.JobService
import android.util.Log
import com.logseq.logseq.runtime.AndroidBackgroundSync
import com.logseq.logseq.runtime.BackgroundSyncResult
import kotlinx.coroutines.*

class AndroidSyncJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val work = mutableMapOf<Int, Job>()

    override fun onStartJob(params: JobParameters): Boolean {
        if (work[params.jobId]?.isActive == true) return true
        work[params.jobId] = scope.launch {
            val result = AndroidBackgroundSync.run(applicationContext)
            Log.i("BackgroundSync", "System sync completed: $result")
            work.remove(params.jobId)
            jobFinished(params, result == BackgroundSyncResult.Retry)
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        work.remove(params.jobId)?.cancel()
        return true
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
