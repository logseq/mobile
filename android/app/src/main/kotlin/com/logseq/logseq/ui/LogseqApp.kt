package com.logseq.logseq.ui

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import android.content.Context
import android.os.Build
import com.logseq.logseq.AudioRecordingService
import com.logseq.logseq.R
import java.util.Locale
import com.logseq.logseq.BuildConfig
import com.logseq.logseq.AndroidAudioTranscriber
import com.logseq.logseq.AndroidRuntimeLogs
import com.logseq.logseq.AndroidRuntimeLogLevel
import com.logseq.logseq.AndroidRuntimeLogSource
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.content.edit
import com.logseq.logseq.runtime.LogseqRuntime
import com.logseq.logseq.runtime.RecordedAudioAsset
import com.logseq.logseq.ui.extensions.LogseqDialogs
import kotlinx.coroutines.launch

// Port of the former Dart app composable + app frame:
// Material theme + a plain surface hosting the LUI backend content,
// plus the modal hosts (audio recording sheet, delete confirmation,
// error snackbar) the runtime requests through LogseqDialogs.
@Composable
internal fun LogseqApp(runtime: LogseqRuntime) {
    val systemDark = isSystemInDarkTheme()
    val dark = when (runtime.effectiveAppearance) {
        "light" -> false
        "dark" -> true
        else -> systemDark
    }
    val window = LocalActivity.current?.window
    SideEffect {
        if (window != null) {
            WindowCompat.getInsetsController(window, window.decorView).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    MaterialExpressiveTheme(
        colorScheme = if (dark) LogseqTheme.darkScheme else LogseqTheme.lightScheme,
        typography = LogseqTheme.typography,
    ) {
        androidx.compose.runtime.CompositionLocalProvider(
            dev.lui.LocalLuiThemeDark provides dark,
            dev.lui.LocalLuiSemanticColors provides LogseqTheme.semanticColors(MaterialTheme.colorScheme),
        ) {
            if (BuildConfig.DEBUG) {
                LaunchedEffect(Unit) {
                    AndroidRuntimeLogs.errors.collect { LogseqDialogs.notifyError(it) }
                }
            }
            Scaffold { padding ->
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .consumeWindowInsets(padding)
                        .windowInsetsPadding(WindowInsets.safeDrawing)
                        // Expose LUI accessibility-identifier testTags as
                        // resource-ids so Maestro `id:` selectors resolve.
                        .semantics { testTagsAsResourceId = true },
                ) {
                    val rootId = runtime.rootNodeId
                    if (rootId != null) {
                        runtime.backend.Content(rootId)
                    }
                }
            }
            val error = if (BuildConfig.DEBUG) LogseqDialogs.errorMessage else null
            if (error != null) {
                AlertDialog(
                    onDismissRequest = LogseqDialogs::clearError,
                    title = { Text("Error") },
                    text = { Text(error) },
                    confirmButton = { TextButton(onClick = LogseqDialogs::clearError) { Text("OK") } },
                )
            }
            AudioRecordingDialog(runtime.audioRecorder)
            DeleteConfirmationDialog()
            JournalCalendarDialog()
            ImageGalleryHost()
            GraphProgressDialog(runtime.graphProgress)
        }
    }
}

@Composable
private fun AudioRecordingDialog(recorder: com.logseq.logseq.AndroidAudioRecorder) {
    val request = LogseqDialogs.recordingRequest ?: return
    val context = LocalContext.current
    val displayLocale = LocalConfiguration.current.locales[0]
    val preferences = remember { context.getSharedPreferences("audio-recording", Context.MODE_PRIVATE) }
    var language by remember(request) {
        mutableStateOf(preferences.getString("language", null)
            ?.let(Locale::forLanguageTag)?.takeIf { it in AndroidAudioTranscriber.languages }
            ?: AndroidAudioTranscriber.defaultLanguage())
    }
    var languageMenu by remember { mutableStateOf(false) }
    val state by AudioRecordingService.state.collectAsState()
    val scope = request.scope
    val locked = state.preparing || state.hasRecording || request.busy
    val transcriptScroll = rememberScrollState()

    LaunchedEffect(request) {
        request.transcriptionEnabled = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            preferences.getBoolean("transcribe", true)
    }
    LaunchedEffect(state.transcript) { transcriptScroll.animateScrollTo(transcriptScroll.maxValue) }

    fun cancel() {
        recorder.cancel()
        request.result.complete(null)
    }

    AlertDialog(
        onDismissRequest = { if (!request.busy && !request.result.isCompleted) cancel() },
        title = { Text(stringResource(R.string.audio_recording)) },
        text = {
            Column {
                if (state.preparing) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    Text(stringResource(R.string.audio_preparing), modifier = Modifier.padding(top = 8.dp))
                } else if (state.hasRecording) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LinearProgressIndicator(progress = { state.level }, modifier = Modifier.weight(1f))
                        Text("%d:%02d".format(state.seconds / 60, state.seconds % 60), modifier = Modifier.padding(start = 12.dp))
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(
                            checked = request.transcriptionEnabled,
                            enabled = !locked,
                            onCheckedChange = {
                                request.transcriptionEnabled = it
                                preferences.edit { putBoolean("transcribe", it) }
                            },
                        )
                        Text(stringResource(R.string.audio_transcribe))
                    }
                    if (request.transcriptionEnabled) {
                        Box {
                            TextButton(enabled = !locked, onClick = { languageMenu = true },
                                modifier = Modifier.testTag("audio.language")) {
                                Text(stringResource(R.string.audio_language) + ": " + language.getDisplayName(displayLocale))
                            }
                            DropdownMenu(expanded = languageMenu, onDismissRequest = { languageMenu = false }) {
                                AndroidAudioTranscriber.languages.sortedBy { it.getDisplayName(displayLocale) }.forEach { item ->
                                    DropdownMenuItem(text = { Text(item.getDisplayName(displayLocale)) }, onClick = {
                                        language = item
                                        preferences.edit { putString("language", item.toLanguageTag()) }
                                        languageMenu = false
                                    })
                                }
                            }
                        }
                    }
                }
                if (state.hasRecording && request.transcriptionEnabled) {
                    SelectionContainer {
                        Text(state.transcript.ifBlank { stringResource(R.string.audio_listening) },
                            modifier = Modifier.padding(top = 12.dp).heightIn(max = 180.dp)
                                .verticalScroll(transcriptScroll).testTag("audio.transcript"))
                    }
                }
                (request.error ?: state.error)?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !request.busy && !request.result.isCompleted && !state.preparing,
                modifier = Modifier.testTag(if (state.hasRecording) "button.audio.stop" else "button.audio.start"),
                onClick = {
                    request.busy = true
                    request.error = null
                    scope.launch {
                        try {
                            if (state.hasRecording) {
                                val recording = recorder.stop()
                                val map = recording.asset
                                request.transcript = recording.transcript
                                request.result.complete(RecordedAudioAsset(
                                    uuid = map["uuid"] as String,
                                    title = map["title"] as String,
                                    assetType = map["assetType"] as String,
                                    size = (map["size"] as Number).toLong(),
                                    checksum = map["checksum"] as String,
                                    localPath = map["localPath"] as String,
                                ))
                            } else {
                                recorder.start(if (request.transcriptionEnabled) language else null)
                            }
                        } catch (cancelled: kotlinx.coroutines.CancellationException) {
                            throw cancelled
                        } catch (failure: Exception) {
                            request.error = failure.localizedMessage
                            AndroidRuntimeLogs.shared.append(AndroidRuntimeLogLevel.ERROR, AndroidRuntimeLogSource.UI, failure.toString())
                        } finally {
                            request.busy = false
                        }
                    }
                },
            ) { Text(stringResource(if (state.hasRecording) R.string.audio_stop else R.string.audio_start)) }
        },
        dismissButton = {
            TextButton(enabled = (!request.busy || state.preparing) && !request.result.isCompleted, onClick = { cancel() }) {
                Text(stringResource(android.R.string.cancel))
            }
        },
    )
}
@Composable
private fun DeleteConfirmationDialog() {
    val request = LogseqDialogs.deleteConfirmation ?: return
    AlertDialog(
        onDismissRequest = { request.result.complete(false) },
        title = { Text(if (request.multiple) "Delete blocks?" else "Delete block?") },
        text = {
            Text(
                if (request.multiple) {
                    "The selected blocks will be removed permanently."
                } else {
                    "The selected block will be removed permanently."
                }
            )
        },
        confirmButton = {
            TextButton(
                modifier = Modifier.testTag("button.confirm-delete"),
                onClick = { request.result.complete(true) },
            ) { Text("Delete") }
        },
        dismissButton = {
            TextButton(onClick = { request.result.complete(false) }) { Text("Cancel") }
        },
    )
}
