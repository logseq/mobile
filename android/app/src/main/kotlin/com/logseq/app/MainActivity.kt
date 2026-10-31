package com.logseq.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Build
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
    private var entryToken = java.util.UUID.randomUUID().toString()
    private var entryHandled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        AndroidE2EECrypto.initialize(applicationContext)
        AndroidHttpTransport.initialize(applicationContext)
        AndroidRuntimeLogs.shared.append(
            AndroidRuntimeLogLevel.INFO,
            AndroidRuntimeLogSource.UI,
            "Android host started",
        )
        super.onCreate(savedInstanceState)
        entryToken = savedInstanceState?.getString("entryToken") ?: entryToken
        entryHandled = savedInstanceState?.getBoolean("entryHandled") ?: false
        // The theme opts out of edge-to-edge enforcement and pins opaque
        // light system bars; the runtime contrast flags keep them opaque.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }

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
        if (!entryHandled) enqueueIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (runtime.authentication.handleCallback(intent.dataString)) return
        entryToken = java.util.UUID.randomUUID().toString()
        entryHandled = false
        enqueueIntent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("entryToken", entryToken)
        outState.putBoolean("entryHandled", entryHandled)
        super.onSaveInstanceState(outState)
    }

    private fun enqueueIntent(intent: Intent?) {
        val token = entryToken
        lifecycleScope.launch {
            try {
                handleAppIntent(intent, token)
                if (entryToken == token) entryHandled = true
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.e("LogseqAppEntry", "Could not retain incoming share", error)
                com.logseq.app.ui.extensions.LogseqDialogs.notifyError(
                    error.message ?: "Could not retain incoming share")
            }
        }
    }

    private fun entryId(token: String, part: String): String =
        java.util.UUID.nameUUIDFromBytes("$token:$part".toByteArray(Charsets.UTF_8)).toString()

    private suspend fun handleAppIntent(intent: Intent?, token: String) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_VIEW) {
            AndroidAppEntryParser.deepLink(intent.dataString)?.let { publishAppEntry(it + ("captureUuid" to entryId(token, "link"))) }
            if (entryToken == token) setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
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
            publishAppEntry(mapOf("kind" to "shared-text", "text" to sharedText, "title" to sharedTitle,
                "captureUuid" to entryId(token, "text")))
        }
        sharedUris(intent).forEach { uri ->
            runtime.assetImporter.importShared(uri, entryId(token, uri.toString()))?.let { asset ->
                publishAppEntry(mapOf("kind" to "shared-asset", "asset" to asset,
                    "captureUuid" to entryId(token, uri.toString())))
            }
        }
        if (entryToken == token) setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
    }

    private suspend fun publishAppEntry(entry: Map<String, Any?>) {
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
