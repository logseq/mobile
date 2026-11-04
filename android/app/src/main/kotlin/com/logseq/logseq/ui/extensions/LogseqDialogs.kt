package com.logseq.logseq.ui.extensions

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.logseq.logseq.runtime.RecordedAudioAsset
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

internal class AudioRecordingRequest(
    val result: CompletableDeferred<RecordedAudioAsset?>,
    val targetBlockId: String?,
    val graphId: String,
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    var busy by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
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

    fun beginAudioRecording(targetBlockId: String?, graphId: String) {
        if (recordingRequest != null) return
        val result = CompletableDeferred<RecordedAudioAsset?>()
        val request = AudioRecordingRequest(
            result = result,
            targetBlockId = targetBlockId,
            graphId = graphId,
        )
        recordingRequest = request
    }

    suspend fun awaitAudioRecording(request: AudioRecordingRequest): Pair<RecordedAudioAsset, String?>? {
        val asset = request.result.await()
        return asset?.let { it to request.transcript }
    }

    fun finishAudioRecording(request: AudioRecordingRequest) {
        if (recordingRequest === request) recordingRequest = null
        request.scope.cancel()
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
