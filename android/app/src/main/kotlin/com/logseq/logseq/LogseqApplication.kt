package com.logseq.logseq

import android.app.Application

class LogseqApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (getProcessName() != packageName) return
        val appearance = getSharedPreferences(AndroidPlatformServices.preferencesName, MODE_PRIVATE)
            .getString("logseq.appearance", "system").orEmpty()
        applyAndroidApplicationAppearance(this, appearance)
        com.logseq.logseq.runtime.AndroidBackgroundSync.schedule(this)
    }
}
