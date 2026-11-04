package com.logseq.logseq

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext

/** One microphone stream feeds both the saved AAC recording and on-device recognition. */
internal class AndroidMicrophoneCapture(
    file: File,
    scope: CoroutineScope,
    private val onAudio: (ByteArray, Int) -> Unit,
    private val onProgress: (Int, Float) -> Unit,
    private val onError: (Throwable) -> Unit,
) {
    private val running = AtomicBoolean(true)
    private val recorder: AudioRecord
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val muxer = try {
        MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    } catch (failure: Throwable) {
        codec.release()
        throw failure
    }
    private var muxerStarted = false
    private var track = -1
    private var frames = 0L
    private val info = MediaCodec.BufferInfo()

    init {
        var input: AudioRecord? = null
        try {
            val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "The microphone does not support 16 kHz recording." }
            @SuppressLint("MissingPermission")
            val initialized = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(max(minimum * 2, 6_400)).build()
            input = initialized
            recorder = initialized
            check(recorder.state == AudioRecord.STATE_INITIALIZED) { "The microphone could not be initialized." }
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "The microphone could not start recording." }
        } catch (failure: Throwable) {
            input?.release()
            codec.release()
            muxer.release()
            throw failure
        }
    }

    private val capture = scope.async(Dispatchers.IO) {
        try {
            val bytes = ByteArray(3_200)
            while (running.get()) {
                val size = recorder.read(bytes, 0, bytes.size, AudioRecord.READ_BLOCKING)
                if (!running.get()) break
                check(size > 0) { "Microphone input was interrupted ($size)." }
                onAudio(bytes, size)
                var offset = 0
                while (offset < size) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = checkNotNull(codec.getInputBuffer(index))
                        buffer.clear()
                        val count = minOf(buffer.remaining(), size - offset)
                        buffer.put(bytes, offset, count)
                        codec.queueInputBuffer(index, 0, count, frames * 1_000_000 / SAMPLE_RATE, 0)
                        frames += count / 2
                        offset += count
                    }
                    drain()
                }
                var peak = 0
                for (i in 0 until size - 1 step 2) {
                    val sample = ((bytes[i].toInt() and 0xff) or (bytes[i + 1].toInt() shl 8)).toShort().toInt()
                    peak = max(peak, abs(sample))
                }
                onProgress((frames / SAMPLE_RATE).toInt(), peak / 32768f)
            }
            val deadline = System.nanoTime() + 5_000_000_000
            var queuedEnd = false
            var ended = false
            while (!ended && System.nanoTime() < deadline) {
                if (!queuedEnd) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        codec.queueInputBuffer(index, 0, 0, frames * 1_000_000 / SAMPLE_RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        queuedEnd = true
                    }
                }
                ended = drain()
            }
            check(ended) { "The audio encoder did not finish." }
        } catch (failure: Throwable) {
            onError(failure)
            throw failure
        } finally {
            recorder.release()
            codec.stop()
            codec.release()
            if (muxerStarted) muxer.stop()
            muxer.release()
        }
    }

    private fun drain(): Boolean {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, 10_000)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                index >= 0 -> {
                    val buffer = checkNotNull(codec.getOutputBuffer(index))
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        check(muxerStarted)
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buffer, info)
                    }
                    val ended = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    codec.releaseOutputBuffer(index, false)
                    if (ended) return true
                }
                else -> return false
            }
        }
    }

    suspend fun stop() = withContext(Dispatchers.IO) {
        if (running.getAndSet(false)) runCatching { recorder.stop() }
        capture.await()
    }

    companion object { private const val SAMPLE_RATE = 16_000 }
}
