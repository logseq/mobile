package com.logseq.app.ui.extensions

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.logseq.app.AndroidAudioRecorder
import com.logseq.app.runtime.RecordedAudioAsset
import kotlinx.coroutines.CompletableDeferred

internal data class AudioRecordingRequest(
    val result: CompletableDeferred<RecordedAudioAsset?>,
    var transcriptionEnabled: Boolean,
    val transcriptionSupported: Boolean,
    val recorder: AndroidAudioRecorder,
)

internal data class DeleteConfirmationRequest(
    val multiple: Boolean,
    val result: CompletableDeferred<Boolean>,
)

// Modal requests surfaced by LogseqRuntime effects/commands and rendered by
// the app composable — the Compose analogue of the previous app's
// dialog/bottom-sheet helpers.
internal object LogseqDialogs {
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
        transcriptionSupported: Boolean,
    ): Pair<RecordedAudioAsset, Boolean>? {
        val result = CompletableDeferred<RecordedAudioAsset?>()
        val request = AudioRecordingRequest(
            result = result,
            transcriptionEnabled = transcriptionSupported,
            transcriptionSupported = transcriptionSupported,
            recorder = recorder,
        )
        recordingRequest = request
        val asset = try {
            result.await()
        } finally {
            recordingRequest = null
        }
        return asset?.let { it to request.transcriptionEnabled }
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
