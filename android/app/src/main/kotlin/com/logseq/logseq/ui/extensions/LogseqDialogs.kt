package com.logseq.logseq.ui.extensions

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.logseq.logseq.AndroidAudioRecorder
import com.logseq.logseq.runtime.RecordedAudioAsset
import kotlinx.coroutines.CompletableDeferred

internal class AudioRecordingRequest(
    val result: CompletableDeferred<RecordedAudioAsset?>,
    val recorder: AndroidAudioRecorder,
) {
    var transcriptionEnabled by mutableStateOf(false)
    var transcript: String? = null
}

internal data class DeleteConfirmationRequest(
    val multiple: Boolean,
    val result: CompletableDeferred<Boolean>,
)

internal data class ImageGalleryRequest(val paths: List<String>, val selectedIndex: Int)

// Modal requests surfaced by LogseqRuntime effects/commands and rendered by
// the app composable — the Compose analogue of the previous app's
// dialog/bottom-sheet helpers.
internal object LogseqDialogs {
    var imageGallery by mutableStateOf<ImageGalleryRequest?>(null)
        private set

    fun openImageGallery(paths: List<String>, selectedIndex: Int) {
        imageGallery = ImageGalleryRequest(paths, selectedIndex)
    }

    fun closeImageGallery() { imageGallery = null }

    var journalCalendar by mutableStateOf<CompletableDeferred<Int?>?>(null)
        private set
    var recordingRequest by mutableStateOf<AudioRecordingRequest?>(null)
        private set
    var deleteConfirmation by mutableStateOf<DeleteConfirmationRequest?>(null)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    suspend fun recordAudio(
        recorder: AndroidAudioRecorder,
    ): Pair<RecordedAudioAsset, String?>? {
        if (recordingRequest != null) return null
        val result = CompletableDeferred<RecordedAudioAsset?>()
        val request = AudioRecordingRequest(
            result = result,
            recorder = recorder,
        )
        recordingRequest = request
        val asset = try {
            result.await()
        } finally {
            recordingRequest = null
        }
        return asset?.let { it to request.transcript }
    }

    suspend fun confirmDeletion(multiple: Boolean): Boolean {
        val result = CompletableDeferred<Boolean>()
        deleteConfirmation = DeleteConfirmationRequest(multiple, result)
        try {
            return result.await()
        } finally {
            deleteConfirmation = null
        }
    }

    suspend fun chooseJournalDate(): Int? {
        val result = CompletableDeferred<Int?>()
        journalCalendar = result
        return try { result.await() } finally { journalCalendar = null }
    }

    fun notifyError(message: String) {
        errorMessage = message
    }

    fun clearError() {
        errorMessage = null
    }
}
