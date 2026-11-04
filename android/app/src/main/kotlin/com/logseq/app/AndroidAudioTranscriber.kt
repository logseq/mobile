package com.logseq.app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
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
import java.io.ByteArrayOutputStream
import java.io.FileOutputStream
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
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

    fun updatePartial(text: String) {
        partial = text.trim()
    }

    fun appendFinal(text: String) {
        val normalized = text.trim()
        if (normalized.isNotEmpty()) finalSegments.add(normalized)
        partial = ""
    }

    fun transcript(): String =
        (finalSegments + listOfNotNull(partial.takeIf { it.isNotEmpty() }))
            .joinToString(" ")
            .trim()
}

object AndroidAudioTranscriber {
    private const val sampleRate = 16_000
    private const val bytesPerSecond = sampleRate * 2

    suspend fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return audioTranscriptionAvailable {
            val recognizer = createRecognizer()
            try {
                recognizer.checkStatus()
            } finally {
                recognizer.close()
            }
        }
    }

    private fun createRecognizer(): SpeechRecognizer = SpeechRecognition.getClient(
        speechRecognizerOptions {
            locale = speechRecognitionLocale(Locale.getDefault())
            preferredMode = SpeechRecognizerOptions.Mode.MODE_BASIC
        },
    )

    suspend fun transcribe(path: String): String = coroutineScope {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "Audio transcription requires Android 12 or later."
        }
        val pcm = decodePcm16(path)
        check(pcm.isNotEmpty()) { "The audio recording is empty." }
        val recognizer = createRecognizer()
        try {
            prepare(recognizer)
            val pipe = ParcelFileDescriptor.createPipe()
            val writer = async { streamAtRealtime(pcm, pipe[1]) }
            val accumulator = AndroidTranscriptAccumulator()
            val request = speechRecognizerRequest {
                audioSource = AudioSource.fromPfd(pipe[0])
            }
            try {
                recognizer.startRecognition(request).collect { response ->
                    when (response) {
                        is SpeechRecognizerResponse.PartialTextResponse ->
                            accumulator.updatePartial(response.text)
                        is SpeechRecognizerResponse.FinalTextResponse ->
                            accumulator.appendFinal(response.text)
                        is SpeechRecognizerResponse.ErrorResponse -> throw response.e
                        SpeechRecognizerResponse.CompletedResponse -> Unit
                    }
                }
            } finally {
                pipe[0].close()
                writer.cancelAndJoin()
            }
            accumulator.transcript()
        } finally {
            recognizer.close()
        }
    }

    private suspend fun prepare(recognizer: SpeechRecognizer) {
        when (recognizer.checkStatus()) {
            FeatureStatus.AVAILABLE -> Unit
            FeatureStatus.DOWNLOADABLE -> {
                val result = recognizer.download().first {
                    it is DownloadStatus.DownloadCompleted ||
                        it is DownloadStatus.DownloadFailed
                }
                if (result is DownloadStatus.DownloadFailed) throw result.e
            }
            FeatureStatus.DOWNLOADING ->
                error("The speech recognition model is still downloading.")
            else -> error("Speech recognition is not available on this device.")
        }
    }

    private suspend fun streamAtRealtime(
        pcm: ByteArray,
        destination: ParcelFileDescriptor,
    ) {
        FileOutputStream(destination.fileDescriptor).use { output ->
            var offset = 0
            val startedAt = System.nanoTime()
            while (offset < pcm.size) {
                val count = minOf(bytesPerSecond / 10, pcm.size - offset)
                output.write(pcm, offset, count)
                output.flush()
                offset += count
                val expectedMilliseconds = offset * 1_000L / bytesPerSecond
                val elapsedMilliseconds = (System.nanoTime() - startedAt) / 1_000_000L
                if (expectedMilliseconds > elapsedMilliseconds) {
                    delay(expectedMilliseconds - elapsedMilliseconds)
                }
            }
        }
        destination.close()
    }

    private fun decodePcm16(path: String): ByteArray {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: error("The recording does not contain an audio track.")
            extractor.selectTrack(trackIndex)
            val inputFormat = extractor.getTrackFormat(trackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: error("The recording has no audio format.")
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0)
            codec.start()

            val output = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputEnded = false
            var outputEnded = false
            while (!outputEnded) {
                if (!inputEnded) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val buffer = codec.getInputBuffer(inputIndex)
                            ?: error("Could not access the audio decoder input buffer.")
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        } else {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                size,
                                extractor.sampleTime,
                                0,
                            )
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> validateOutputFormat(codec.outputFormat)
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (outputIndex >= 0) {
                        codec.getOutputBuffer(outputIndex)?.let { buffer ->
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val bytes = ByteArray(info.size)
                            buffer.get(bytes)
                            output.write(bytes)
                        }
                        outputEnded =
                            info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                }
            }
            return output.toByteArray()
        } finally {
            runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
        }
    }

    private fun validateOutputFormat(format: MediaFormat) {
        check(
            format.getInteger(MediaFormat.KEY_SAMPLE_RATE) == sampleRate &&
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 1,
        ) { "The decoded recording must be 16 kHz mono PCM." }
        if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            check(
                format.getInteger(MediaFormat.KEY_PCM_ENCODING) ==
                    AudioFormat.ENCODING_PCM_16BIT,
            ) { "The decoded recording must use 16-bit PCM." }
        }
    }
}
