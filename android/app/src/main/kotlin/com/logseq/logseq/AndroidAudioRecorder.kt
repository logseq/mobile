package com.logseq.logseq

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.Locale
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class AndroidAudioRecorder(private val activity: Activity) {
    private var pendingPermission: CancellableContinuation<Unit>? = null

    suspend fun start(language: Locale? = null) {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            suspendCancellableCoroutine { continuation ->
                pendingPermission = continuation
                continuation.invokeOnCancellation { pendingPermission = null }
                ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.RECORD_AUDIO), microphonePermissionRequest)
            }
        }
        AudioRecordingService.start(activity.applicationContext, language)
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != microphonePermissionRequest) return false
        val continuation = pendingPermission ?: return true
        pendingPermission = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            continuation.resume(Unit)
        } else {
            continuation.resumeWithException(SecurityException("Microphone access is required to record audio."))
        }
        return true
    }

    suspend fun stop(): AudioRecordingResult = AudioRecordingService.stop()

    fun cancel() {
        pendingPermission?.cancel()
        pendingPermission = null
        AudioRecordingService.cancel()
    }

    private companion object { const val microphonePermissionRequest = 4921 }
}
