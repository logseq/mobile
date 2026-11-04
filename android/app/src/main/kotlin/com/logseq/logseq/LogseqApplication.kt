package com.logseq.logseq

import android.app.Application

class LogseqApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (getProcessName() != packageName) return
        com.logseq.logseq.runtime.AndroidBackgroundSync.schedule(this)
    }
}
