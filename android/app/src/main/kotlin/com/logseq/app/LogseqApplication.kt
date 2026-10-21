package com.logseq.app

import android.app.Application

class LogseqApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        com.logseq.app.runtime.AndroidBackgroundSync.schedule(this)
    }
}
