package com.logseq.app

import com.google.mlkit.genai.common.FeatureStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AndroidAudioTranscriberTest {
    @Test
    fun chineseSystemLocalesUseTheMandarinModelIdentifiers() {
        for (tag in listOf("zh", "zh-CN", "zh-SG", "zh-Hans-CN", "zh-Hans-TW")) {
            assertEquals(tag, "cmn-Hans-CN", speechRecognitionLocale(Locale.forLanguageTag(tag)).toLanguageTag())
        }
        for (tag in listOf("zh-TW", "zh-HK", "zh-MO", "zh-Hant", "zh-Hant-CN")) {
            assertEquals(tag, "cmn-Hant-TW", speechRecognitionLocale(Locale.forLanguageTag(tag)).toLanguageTag())
        }
    }

    @Test
    fun otherRecognitionLanguagesKeepTheirOriginalLocale() {
        for (tag in listOf("en-US", "de-DE", "ja-JP", "cmn-Hans-CN", "yue-Hant-HK")) {
            val locale = Locale.forLanguageTag(tag)
            assertEquals(locale, speechRecognitionLocale(locale))
        }
    }

    @Test
    fun transcriptionRequiresAUsableEngine() = runBlocking {
        var checked = false
        assertTrue(audioTranscriptionAvailable {
            checked = true
            FeatureStatus.AVAILABLE
        })
        assertTrue(checked)
        assertTrue(audioTranscriptionAvailable { FeatureStatus.DOWNLOADABLE })
        assertFalse(audioTranscriptionAvailable { FeatureStatus.UNAVAILABLE })
        assertFalse(audioTranscriptionAvailable { FeatureStatus.DOWNLOADING })
    }

    @Test
    fun failedOrUnresponsiveEngineDoesNotOfferTranscription() = runBlocking {
        assertFalse(audioTranscriptionAvailable { error("Recognition service missing") })
        assertFalse(audioTranscriptionAvailable(timeoutMilliseconds = 10) {
            delay(10_000)
            FeatureStatus.AVAILABLE
        })
    }

    @Test
    fun dismissingRecordingCancelsTheCapabilityCheck() = runBlocking {
        try {
            audioTranscriptionAvailable { throw CancellationException("Recording dismissed") }
            fail("Cancellation must propagate to the recording dialog")
        } catch (expected: CancellationException) {
            assertEquals("Recording dismissed", expected.message)
        }
    }

    @Test
    fun finalSegmentsReplaceTheirPrecedingPartialResult() {
        val accumulator = AndroidTranscriptAccumulator()

        accumulator.updatePartial("  first partial ")
        accumulator.appendFinal(" first final ")
        accumulator.updatePartial(" second partial ")

        assertEquals("first final second partial", accumulator.transcript())
    }

    @Test
    fun emptyRecognitionUpdatesDoNotCreateTranscriptWhitespace() {
        val accumulator = AndroidTranscriptAccumulator()

        accumulator.updatePartial("  ")
        accumulator.appendFinal("")

        assertEquals("", accumulator.transcript())
    }
}
