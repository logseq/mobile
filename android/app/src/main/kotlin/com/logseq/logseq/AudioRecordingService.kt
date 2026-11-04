package com.logseq.logseq

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.content.ContextCompat
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class AudioRecordingState(
    val preparing: Boolean = false,
    val recording: Boolean = false,
    val hasRecording: Boolean = false,
    val seconds: Int = 0,
    val level: Float = 0f,
    val transcript: String = "",
    val error: String? = null,
)

data class AudioRecordingResult(val asset: Map<String, Any>, val transcript: String?)

/** Keeps capture and recognition alive independently of the Activity, including under keyguard. */
class AudioRecordingService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var microphone: AndroidMicrophoneCapture? = null
    private var transcription: AndroidLiveTranscription? = null
    private var file: File? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var finishing = false
    private var cancelled = false
    private var preparation: Job? = null
    @Volatile private var captureFailure: Throwable? = null
    private val destroyed = CompletableDeferred<Unit>()

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START || started?.isCancelled == true) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (preparation != null) return START_NOT_STICKY
        try {
            showNotification()
            preparation = scope.launch {
                try {
                    val language = intent.getStringExtra(EXTRA_LANGUAGE)?.let(Locale::forLanguageTag)
                    val recognizer: SpeechRecognizer? = language?.let { AndroidAudioTranscriber.prepare(it) }
                    if (cancelled) {
                        recognizer?.close()
                        return@launch
                    }
                    val recordingFile = File(cacheDir, "recording-${UUID.randomUUID()}.m4a")
                    file = recordingFile
                    transcription = recognizer?.let {
                        AndroidLiveTranscription(it, scope,
                            onText = { text -> mutableState.update { state -> state.copy(transcript = text) } },
                            onError = { failure -> mutableState.update { state -> state.copy(error = failure.localizedMessage) } },
                        )
                    }
                    wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Logseq:AudioRecording").apply {
                            acquire(12 * 60 * 60 * 1_000L)
                        }
                    microphone = AndroidMicrophoneCapture(recordingFile, scope,
                        onAudio = { bytes, size -> transcription?.append(bytes, size) },
                        onProgress = { seconds, level ->
                            mutableState.update { state -> state.copy(seconds = seconds, level = level) }
                            if (seconds >= MAXIMUM_SECONDS) scope.launch { pauseCapture() }
                        },
                        onError = { failure ->
                            captureFailure = failure
                            mutableState.update { state -> state.copy(recording = false, error = failure.localizedMessage) }
                        },
                    )
                    mutableState.update { it.copy(preparing = false, recording = true, hasRecording = true) }
                    started?.complete(Unit)
                } catch (failure: Throwable) {
                    mutableState.update { it.copy(preparing = false, recording = false, error = failure.localizedMessage) }
                    started?.completeExceptionally(failure)
                    cancelRecording()
                }
            }
        } catch (failure: Exception) {
            started?.completeExceptionally(failure)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun showNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.audio_recording), NotificationManager.IMPORTANCE_LOW))
        val openApp = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(getString(R.string.audio_notification_title))
            .setContentText(getString(R.string.audio_notification_body))
            .setContentIntent(openApp)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private suspend fun finishRecording(): AudioRecordingResult {
        check(!finishing) { "The recording is already being saved." }
        finishing = true
        try {
            pauseCapture()
            captureFailure?.let { throw it }
            // Recognition failure must never discard the audio recording.
            try { transcription?.finish() } catch (failure: Exception) {
                mutableState.update { it.copy(error = failure.localizedMessage) }
            }
            transcription = null
            val source = checkNotNull(file) { "No audio was recorded." }
            val asset = withContext(Dispatchers.IO) {
                check(source.length() > 0) { "The audio recording is empty." }
                val digest = MessageDigest.getInstance("SHA-256")
                source.inputStream().use { input ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
                val checksum = digest.digest().joinToString("") { "%02x".format(it) }
                val timestamp = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.getDefault()).format(Date())
                mapOf(
                    "uuid" to UUID.randomUUID().toString().lowercase(Locale.US),
                    "title" to "Audio-$timestamp.m4a", "assetType" to "m4a",
                    "size" to source.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                    "checksum" to checksum, "localPath" to source.absolutePath,
                )
            }
            file = null // Ownership passes to the attachment import flow.
            return AudioRecordingResult(asset, state.value.transcript.trim().takeIf { it.isNotEmpty() })
        } finally {
            mutableState.value = AudioRecordingState()
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private suspend fun cancelRecording() = withContext(NonCancellable) {
        cancelled = true
        preparation?.cancel()
        started?.cancel()
        runCatching { pauseCapture() }
        transcription?.close()
        transcription = null
        file?.delete()
        file = null
        releaseWakeLock()
        mutableState.update { it.copy(preparing = false, recording = false, hasRecording = false, level = 0f) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private suspend fun pauseCapture() {
        val active = microphone
        microphone = null
        val failure = stopAudioCapture { active?.stop() }
        if (failure != null) {
            captureFailure = failure
            mutableState.update { it.copy(error = failure.localizedMessage) }
        }
        mutableState.update { it.copy(recording = false, level = 0f) }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        preparation?.cancel()
        scope.launch {
            try {
                runCatching { microphone?.stop() }
                transcription?.close()
                file?.delete()
                releaseWakeLock()
            } finally {
                destroyed.complete(Unit)
                scope.cancel()
            }
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val ACTION_START = "com.logseq.logseq.audio.START"
        private const val EXTRA_LANGUAGE = "language"
        private const val CHANNEL = "audio-recording"
        private const val NOTIFICATION_ID = 8003
        private const val MAXIMUM_SECONDS = 10 * 60
        private var instance: AudioRecordingService? = null
        private var started: CompletableDeferred<Unit>? = null
        private val mutableState = MutableStateFlow(AudioRecordingState())
        val state = mutableState.asStateFlow()

        suspend fun start(context: Context, language: Locale?) {
            if (state.value.hasRecording || state.value.preparing) {
                started?.await()
                return
            }
            instance?.destroyed?.await()
            mutableState.value = AudioRecordingState(preparing = true)
            val ready = CompletableDeferred<Unit>()
            started = ready
            try {
                ContextCompat.startForegroundService(context, Intent(context, AudioRecordingService::class.java)
                    .setAction(ACTION_START).putExtra(EXTRA_LANGUAGE, language?.toLanguageTag()))
                ready.await()
            } catch (failure: Throwable) {
                mutableState.update { it.copy(preparing = false, error = failure.localizedMessage) }
                instance?.scope?.launch { instance?.cancelRecording() }
                throw failure
            }
        }

        suspend fun stop(): AudioRecordingResult = checkNotNull(instance).finishRecording()

        fun cancel() {
            started?.cancel()
            instance?.let { it.scope.launch { it.cancelRecording() } }
        }
    }
}
