package com.logseq.logseq

import android.os.Build
import android.os.ParcelFileDescriptor
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

internal fun speechRecognitionLocale(locale: Locale): Locale {
    if (locale.language != "zh") return locale
    val traditional = when (locale.script) {
        "Hans" -> false
        "Hant" -> true
        else -> locale.country in setOf("TW", "HK", "MO")
    }
    return Locale.forLanguageTag(if (traditional) "cmn-Hant-TW" else "cmn-Hans-CN")
}

internal suspend fun audioTranscriptionAvailable(
    timeoutMilliseconds: Long = 5_000,
    checkStatus: suspend () -> Int,
): Boolean = try {
    withTimeoutOrNull(timeoutMilliseconds) {
        when (checkStatus()) {
            FeatureStatus.AVAILABLE, FeatureStatus.DOWNLOADABLE -> true
            else -> false
        }
    } ?: false
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (_: Exception) {
    false
}

class AndroidTranscriptAccumulator {
    private val finalSegments = mutableListOf<String>()
    private var partial = ""

    fun updatePartial(text: String) { partial = text.trim() }

    fun appendFinal(text: String) {
        val normalized = text.trim()
        if (normalized.isNotEmpty()) finalSegments.add(normalized)
        partial = ""
    }

    fun transcript(): String =
        (finalSegments + listOfNotNull(partial.takeIf { it.isNotEmpty() }))
            .joinToString(" ").trim()
}

object AndroidAudioTranscriber {
    // Basic-mode locales published by ML Kit; availability still depends on the device.
    val languages: List<Locale> = listOf(
        "cmn-Hans-CN", "cmn-Hant-TW", "de-DE", "en-US", "es-ES", "fr-FR", "hi-IN",
        "it-IT", "ja-JP", "ko-KR", "pl-PL", "pt-BR", "ru-RU", "tr-TR", "vi-VN",
    ).map(Locale::forLanguageTag)

    fun defaultLanguage(): Locale {
        val current = speechRecognitionLocale(Locale.getDefault())
        return languages.firstOrNull { it == current }
            ?: languages.firstOrNull { it.language == current.language }
            ?: Locale.US
    }

    suspend fun isSupported(locale: Locale = defaultLanguage()): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return audioTranscriptionAvailable {
            val recognizer = createRecognizer(locale)
            try { recognizer.checkStatus() } finally { recognizer.close() }
        }
    }

    private fun createRecognizer(language: Locale): SpeechRecognizer = SpeechRecognition.getClient(
        speechRecognizerOptions {
            locale = speechRecognitionLocale(language)
            preferredMode = SpeechRecognizerOptions.Mode.MODE_BASIC
        },
    )

    internal suspend fun prepare(locale: Locale): SpeechRecognizer {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "Audio transcription requires Android 12 or later."
        }
        val recognizer = createRecognizer(locale)
        try {
            when (recognizer.checkStatus()) {
                FeatureStatus.AVAILABLE -> Unit
                FeatureStatus.DOWNLOADABLE -> {
                    val result = recognizer.download().first {
                        it is DownloadStatus.DownloadCompleted || it is DownloadStatus.DownloadFailed
                    }
                    if (result is DownloadStatus.DownloadFailed) throw result.e
                }
                FeatureStatus.DOWNLOADING -> error("The speech recognition model is still downloading.")
                else -> error("Speech recognition is not available for this language on this device.")
            }
            return recognizer
        } catch (failure: Throwable) {
            recognizer.close()
            throw failure
        }
    }
}

internal class AndroidLiveTranscription(
    private val recognizer: SpeechRecognizer,
    scope: CoroutineScope,
    private val onText: (String) -> Unit,
    private val onError: (Throwable) -> Unit,
) {
    private val pipe = ParcelFileDescriptor.createPipe()
    private val chunks = Channel<ByteArray>(20)
    private val accumulator = AndroidTranscriptAccumulator()
    private val failed = AtomicBoolean(false)
    private val writer = scope.launch(Dispatchers.IO) {
        try {
            ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { output ->
                for (chunk in chunks) output.write(chunk)
            }
        } catch (failure: Exception) {
            if (failure !is CancellationException && failed.compareAndSet(false, true)) onError(failure)
        }
    }
    private val results = scope.async(Dispatchers.IO) {
        try {
            val request = speechRecognizerRequest { audioSource = AudioSource.fromPfd(pipe[0]) }
            recognizer.startRecognition(request).collect { response ->
                when (response) {
                    is SpeechRecognizerResponse.PartialTextResponse -> accumulator.updatePartial(response.text)
                    is SpeechRecognizerResponse.FinalTextResponse -> accumulator.appendFinal(response.text)
                    is SpeechRecognizerResponse.ErrorResponse -> throw response.e
                    SpeechRecognizerResponse.CompletedResponse -> Unit
                }
                onText(accumulator.transcript())
            }
        } catch (failure: Exception) {
            if (failure !is CancellationException && failed.compareAndSet(false, true)) onError(failure)
        } finally {
            chunks.close()
            pipe[0].close()
        }
    }

    fun append(bytes: ByteArray, size: Int) {
        if (!failed.get() && chunks.trySend(bytes.copyOf(size)).isFailure && failed.compareAndSet(false, true)) {
            chunks.close()
            onError(IllegalStateException("Live transcription could not keep up. The audio is still being recorded."))
        }
    }

    suspend fun finish() {
        chunks.close()
        try {
            withTimeout(10_000) {
                writer.join()
                recognizer.stopRecognition()
                results.await()
            }
        } finally {
            close()
        }
    }

    suspend fun close() {
        chunks.cancel()
        pipe[0].close()
        pipe[1].close()
        writer.cancelAndJoin()
        results.cancelAndJoin()
        recognizer.close()
    }
}
