package com.logseq.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

class AndroidAudioRecorder(private val activity: Activity) {
    private val context: Context = activity.applicationContext
    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var pendingStart: Continuation<Unit>? = null

    suspend fun start() {
        check(recorder == null && pendingStart == null) {
            "An audio recording is already active."
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(logTag, "start permission=granted")
            startRecorder()
            return
        }
        Log.i(logTag, "start permission=requested")
        suspendCoroutine { continuation ->
            pendingStart = continuation
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                microphonePermissionRequest,
            )
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != microphonePermissionRequest) return false
        val continuation = pendingStart ?: return true
        pendingStart = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            Log.i(logTag, "permission result=granted")
            runCatching(::startRecorder)
                .onSuccess { continuation.resume(Unit) }
                .onFailure(continuation::resumeWithException)
        } else {
            Log.w(logTag, "permission result=denied")
            continuation.resumeWithException(
                SecurityException("Microphone access is required to record audio."),
            )
        }
        return true
    }

    fun stop(): Map<String, Any> {
        val activeRecorder = recorder ?: error("No audio recording is active.")
        val file = outputFile ?: error("No audio output file is active.")
        val startedAt = SystemClock.elapsedRealtime()
        Log.i(logTag, "stop begin")
        return runCatching {
            activeRecorder.stop()
            activeRecorder.release()
            recorder = null
            outputFile = null
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            check(file.length() > 0) { "The audio recording is empty." }
            Log.i(
                logTag,
                "stop complete elapsedMs=${SystemClock.elapsedRealtime() - startedAt} size=${file.length()}",
            )
            mapOf(
                "uuid" to UUID.randomUUID().toString().lowercase(Locale.US),
                "title" to file.name,
                "assetType" to "m4a",
                "size" to file.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                "checksum" to digest.digest().joinToString("") { "%02x".format(it) },
                "localPath" to file.absolutePath,
            )
        }.getOrElse { error ->
            Log.e(
                logTag,
                "stop failed elapsedMs=${SystemClock.elapsedRealtime() - startedAt}",
                error,
            )
            activeRecorder.release()
            recorder = null
            outputFile = null
            file.delete()
            throw error
        }
    }

    fun cancel() {
        Log.i(logTag, "cancel active=${recorder != null} pendingPermission=${pendingStart != null}")
        pendingStart?.resumeWithException(
            IllegalStateException("Audio recording was canceled."),
        )
        pendingStart = null
        runCatching { recorder?.stop() }
        recorder?.release()
        recorder = null
        outputFile?.delete()
        outputFile = null
    }

    @Suppress("DEPRECATION")
    private fun startRecorder() {
        val directory = File(context.cacheDir, "Assets").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.US).format(Date())
        val file = File(directory, "Audio-$stamp.m4a")
        val next = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            MediaRecorder()
        }
        try {
            next.setAudioSource(MediaRecorder.AudioSource.MIC)
            next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            next.setAudioSamplingRate(16_000)
            next.setAudioChannels(1)
            next.setOutputFile(file.absolutePath)
            next.setMaxDuration(maximumDurationMilliseconds)
            next.prepare()
            next.start()
            recorder = next
            outputFile = file
            Log.i(logTag, "start complete")
        } catch (error: Throwable) {
            Log.e(logTag, "start failed", error)
            next.release()
            file.delete()
            throw error
        }
    }

    private companion object {
        const val microphonePermissionRequest = 4921
        const val maximumDurationMilliseconds = 10 * 60 * 1000
        const val logTag = "LogseqAudioRecorder"
    }
}
