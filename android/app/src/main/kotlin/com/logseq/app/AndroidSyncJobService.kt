package com.logseq.app

import android.app.job.JobParameters
import android.app.job.JobService
import android.util.Log
import com.logseq.app.runtime.AndroidBackgroundSync
import com.logseq.app.runtime.BackgroundSyncResult
import kotlinx.coroutines.*

class AndroidSyncJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var work: Job? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (work?.isActive == true) return true
        work = scope.launch {
            val result = AndroidBackgroundSync.run(applicationContext)
            Log.i("BackgroundSync", "System sync completed: $result")
            jobFinished(params, result == BackgroundSyncResult.Retry)
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        work?.cancel()
        return true
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
