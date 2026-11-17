package com.logseq.logseq

import android.app.Application
import io.sentry.Sentry
import io.sentry.android.core.SentryAndroid

class LogseqApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (getProcessName() != packageName) return
        if (!BuildConfig.DEBUG || BuildConfig.SENTRY_DEBUG) {
            SentryAndroid.init(this) { options ->
                options.dsn = "https://0f55ac2d59aece205141edb2d24ceb16@o416451.ingest.us.sentry.io/4512448513179648"
                options.environment = if (BuildConfig.DEBUG) "development" else "production"
                options.isAnrEnabled = true
                options.isAnrReportInDebug = BuildConfig.SENTRY_DEBUG
                options.isEnableNdk = true
                options.isEnableScopeSync = true
                options.isSendDefaultPii = false
                options.isEnableAutoSessionTracking = false
                options.maxBreadcrumbs = 0
                options.setBeforeSend { event, _ ->
                    // Exception messages can contain graph names, paths, or user content.
                    event.exceptions?.forEach { if (it.type != null) it.value = null }
                    event.user = null
                    event.request = null
                    event
                }
            }
            Sentry.setTag("git_revision", BuildConfig.GIT_REVISION)
        }
        val appearance = getSharedPreferences(AndroidPlatformServices.preferencesName, MODE_PRIVATE)
            .getString("logseq.appearance", "system").orEmpty()
        applyAndroidApplicationAppearance(this, appearance)
        com.logseq.logseq.runtime.AndroidBackgroundSync.schedule(this)
    }
}
