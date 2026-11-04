package com.logseq.logseq

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest)
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode == notificationPermissionRequest) return true
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

    fun setTranscriptionLanguage(language: Locale?) = AudioRecordingService.setTranscriptionLanguage(language)

    fun detach() {
        pendingPermission?.cancel()
        pendingPermission = null
    }

    fun cancel() {
        detach()
        AudioRecordingService.cancel()
    }

    private companion object {
        const val microphonePermissionRequest = 4921
        const val notificationPermissionRequest = 4922
    }
}
