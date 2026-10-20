package com.logseq.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.doOnPreDraw
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.logseq.app.runtime.AndroidLaunchMetrics
import com.logseq.app.runtime.LogseqRuntime
import com.logseq.app.ui.LogseqApp
import kotlinx.coroutines.launch
import logseq.app.AndroidE2EECrypto
import logseq.app.AndroidHttpTransport
import logseq.app.AndroidRuntimeLogLevel
import logseq.app.AndroidRuntimeLogSource
import logseq.app.AndroidRuntimeLogs

class MainActivity : ComponentActivity() {
    private lateinit var runtime: LogseqRuntime

    override fun onCreate(savedInstanceState: Bundle?) {
        AndroidE2EECrypto.initialize(applicationContext)
        AndroidHttpTransport.initialize(applicationContext)
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.INFO,
            AndroidRuntimeLogSource.UI,
            "Android host started",
        )
        super.onCreate(savedInstanceState)
        // The theme opts out of edge-to-edge enforcement and pins opaque
        // light system bars; the runtime contrast flags keep them opaque.
        window.isStatusBarContrastEnforced = false
        window.isNavigationBarContrastEnforced = false

        runtime = LogseqRuntime(this, lifecycleScope)
        runtime.start()

        AndroidLaunchMetrics.activity = this
        setContent {
            LogseqApp(runtime)
        }
        window.decorView.doOnPreDraw {
            AndroidLaunchMetrics.report("first_ui_rendered")
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                runtime.onLifecycleResumed(resumed = true)
                try {
                    kotlinx.coroutines.awaitCancellation()
                } finally {
                    runtime.onLifecycleResumed(resumed = false)
                }
            }
        }
        handleAppIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (runtime.authentication.handleCallback(intent.dataString)) return
        handleAppIntent(intent)
    }

    private fun handleAppIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_VIEW) {
            AndroidAppEntryParser.deepLink(intent.dataString)?.let(::publishAppEntry)
            return
        }
        if (intent.action != Intent.ACTION_SEND &&
            intent.action != Intent.ACTION_SEND_MULTIPLE
        ) {
            return
        }
        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
        val sharedTitle = intent.getStringExtra(Intent.EXTRA_TITLE)
        if (!sharedText.isNullOrBlank() || !sharedTitle.isNullOrBlank()) {
            publishAppEntry(mapOf("kind" to "shared-text", "text" to sharedText, "title" to sharedTitle))
        }
        sharedUris(intent).forEach { uri ->
            lifecycleScope.launch {
                runtime.assetImporter.importShared(uri)?.let { asset ->
                    publishAppEntry(mapOf("kind" to "shared-asset", "asset" to asset))
                }
            }
        }
    }

    private fun publishAppEntry(entry: Map<String, Any?>) {
        Log.i("LogseqAppEntry", "Publishing kind=${entry["kind"]}")
        runtime.publishAppEntry(entry)
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.INFO,
            AndroidRuntimeLogSource.UI,
            "Received Android app entry kind=${entry["kind"]}",
        )
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> = buildList {
        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(::addAll)
        intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::add)
        intent.clipData?.let { clips ->
            for (index in 0 until clips.itemCount) {
                clips.getItemAt(index).uri?.let(::add)
            }
        }
    }.distinct()

    @Deprecated("Android activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (runtime.assetImporter.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        if (runtime.audioRecorder.onRequestPermissionsResult(requestCode, grantResults)) return
        // Permissions the importer or other services may request fall
        // through to the platform default.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        if (::runtime.isInitialized) {
            runtime.audioRecorder.cancel()
            runtime.audioPlayer.release()
            runtime.dispose()
        }
        super.onDestroy()
    }
}
