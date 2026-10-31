package com.logseq.app

import android.app.Application

class LogseqApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (getProcessName() != packageName) return
        com.logseq.app.runtime.AndroidBackgroundSync.schedule(this)
    }
}
