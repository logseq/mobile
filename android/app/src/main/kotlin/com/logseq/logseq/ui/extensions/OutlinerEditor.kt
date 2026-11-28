package com.logseq.logseq.ui.extensions

import android.net.Uri
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.TextAttribute
import androidx.annotation.RequiresApi
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent as ComposeKeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.onPreInterceptKeyBeforeSoftKeyboard
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuKeys
import androidx.compose.foundation.text.contextmenu.builder.item
import androidx.compose.foundation.text.contextmenu.modifier.appendTextContextMenuComponents
import androidx.compose.foundation.text.contextmenu.modifier.filterTextContextMenuComponents
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import dev.lui.LuiExtensionContext
import com.logseq.logseq.AndroidBlockClipboard
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import com.logseq.logseq.runtime.NativeEditorInput
import kotlinx.coroutines.delay

// Port of the former _OutlinerEditor Dart implementation.
//
// The block title/caret are owned by the OCaml core. Local edits emit
// text-change (debounced 80ms), the block-creation key emits return, backspace at offset 0
// emits a structural backspace. Model acknowledgements echo locally
// published titles — those updates are swallowed so typing is never
// reverted mid-keystroke.
private sealed interface EditorHandoff {
    data class Return(val title: String, val caret: Int) : EditorHandoff
    data class Paste(val payload: String) : EditorHandoff
}

private class EditorRef<T>(var value: T)

private operator fun <T> EditorRef<T>.getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>): T = value

private operator fun <T> EditorRef<T>.setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, next: T) {
    value = next
}

private class EditorFieldValue(private val state: TextFieldState) {
    var prefix: String = ""

    fun read(): TextFieldValue {
        val offset = prefix.length
        fun TextRange.afterPrefix() = TextRange((start - offset).coerceAtLeast(0), (end - offset).coerceAtLeast(0))
        // An IME can reopen the previous word's composing span during a block split.
        val composition = state.composition?.takeIf { it.max > offset }?.afterPrefix()
        return TextFieldValue(
            state.text.drop(offset).toString(), state.selection.afterPrefix(), composition,
        )
    }

    operator fun getValue(owner: Any?, property: kotlin.reflect.KProperty<*>): TextFieldValue =
        read()

    operator fun setValue(owner: Any?, property: kotlin.reflect.KProperty<*>, next: TextFieldValue) {
        val text = prefix + next.text
        val selection = TextRange(prefix.length + next.selection.start, prefix.length + next.selection.end)
        val compositionToCommit = state.composition.takeIf { next.composition == null }
        val textChanged = state.text.toString() != text
        if (!textChanged && state.selection == selection && compositionToCommit == null) return
        state.edit {
            if (textChanged) {
                replace(0, length, text)
            } else if (compositionToCommit != null) {
                // A programmatic edit must touch the buffer to finish an unchanged composing span.
                val start = compositionToCommit.min
                val end = compositionToCommit.max
                replace(start, end, text.substring(start, end))
            }
            this.selection = selection
        }
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
internal fun OutlinerEditor(
    context: LuiExtensionContext,
    importPastedImage: (suspend (Uri) -> JSONObject)? = null,
) {
    val blockId = context.string("block-id") ?: ""
    val modelTitle = context.string("title") ?: ""
    val modelCaret = context.int("caret-utf16-offset") ?: -1
    val selectionRevision = context.int("selection-revision") ?: 0
    val inputPolicy = context.string("input-policy") ?: "{}"
    val focusEnabled = context.bool("focus-enabled") == true
    val code = remember(inputPolicy) { runCatching { org.json.JSONObject(inputPolicy).optBoolean("code") }.getOrDefault(false) }
    val multiline = remember(inputPolicy) { runCatching { org.json.JSONObject(inputPolicy).optBoolean("multiline") }.getOrDefault(false) }
    val codeLanguage = remember(inputPolicy) { runCatching { org.json.JSONObject(inputPolicy).optString("language") }.getOrDefault("") }

    val focusRequester = remember { FocusRequester() }
    val fieldState = remember { TextFieldState(modelTitle, TextRange(modelCaret.coerceIn(0, modelTitle.length))) }
    val nativeValue = remember { EditorFieldValue(fieldState) }
    var value: TextFieldValue by nativeValue
    var observedValue: TextFieldValue by remember { EditorRef(nativeValue.read()) }
    var compositionStartText: String? by remember { EditorRef<String?>(null) }
    val preImeEnterKeys = remember { mutableSetOf<Key>() }
    var previousText: String by remember { EditorRef(modelTitle) }
    var previousSelection: TextRange by remember { EditorRef(observedValue.selection) }
    var rememberedModelTitle: String by remember { EditorRef(modelTitle) }
    var rememberedSelectionRevision: Int by remember { EditorRef(selectionRevision) }
    var rememberedBlockId: String by remember { EditorRef(blockId) }
    var awaitingHandoff: Boolean by remember { EditorRef(false) }
    var retainedReturn: EditorHandoff.Return? by remember { EditorRef<EditorHandoff.Return?>(null) }
    // Each segment buffers native edits after a structural edit until acknowledgement.
    val handoffSegments = remember { ArrayDeque<PendingEditorInput>() }
    val queuedHandoffs = remember { ArrayDeque<EditorHandoff>() }
    var applyingModel: Boolean by remember { EditorRef(false) }
    var debounceJob: kotlinx.coroutines.Job? by remember { EditorRef<kotlinx.coroutines.Job?>(null) }
    var handoffRevision: Int? by remember { EditorRef<Int?>(null) }
    val nativeToolbar = LocalTextToolbar.current
    val androidContext = LocalContext.current
    val pasteLabel = stringResource(android.R.string.paste)
    val clipboard = remember(androidContext) {
        androidContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    }
    val pasteScope = rememberCoroutineScope()
    val latestBlockId by rememberUpdatedState(blockId)
    val latestSelectionRevision by rememberUpdatedState(selectionRevision)
    var importingImages by remember { mutableStateOf(false) }
    val pasteKey = remember { Any() }
    val publishedTitles = remember { mutableListOf<String>() }
    var publishedInput: Triple<String, Int, Boolean>? by remember { EditorRef<Triple<String, Int, Boolean>?>(null) }
    var handoffEvent: EditorHandoff? by remember { EditorRef<EditorHandoff?>(null) }

    fun cancelDebounce() {
        debounceJob?.cancel()
        debounceJob = null
    }

    fun applyNativeValue(next: TextFieldValue) {
        // Snapshot observers can run during the edit. Mark it before writing.
        if (next.composition == null) compositionStartText = null
        observedValue = next
        value = next
    }

    fun keepPrefix(prefix: String, input: TextFieldValue) {
        nativeValue.prefix = prefix
        applyNativeValue(input)
    }

    fun capturePendingInput(incoming: TextFieldValue) {
        if (!awaitingHandoff) return
        handoffSegments.lastOrNull()?.capture(incoming.text, incoming.selection.start, incoming.selection.end)
        observedValue = incoming
    }

    // Show an acknowledged block immediately. An active IME must keep its
    // original buffer until it finishes replacing the composing range.
    val handoffAcknowledged = handoffRevision != null && selectionRevision != handoffRevision
    val canReconcileHandoff = awaitingHandoff && (blockId != rememberedBlockId || handoffAcknowledged)
    val composingAcrossHandoff = canReconcileHandoff && value.composition != null
    var needsDebounceAfterReconcile = false
    if (canReconcileHandoff && !composingAcrossHandoff) {
        val buffered = value
        capturePendingInput(buffered)
        handoffRevision = null
        val pending = handoffSegments.removeFirstOrNull()
        val offset = modelCaret.coerceIn(0, modelTitle.length)
        val snapshot = pending?.rebase(modelTitle, offset) ?: EditorInputSnapshot(modelTitle, offset)
        val merged = snapshot.text
        val caret = snapshot.selectionStart
        val selection = TextRange(snapshot.selectionStart, snapshot.selectionEnd)
        rememberedBlockId = blockId
        rememberedModelTitle = modelTitle
        rememberedSelectionRevision = selectionRevision
        publishedTitles.clear()
        publishedInput = null
        awaitingHandoff = handoffSegments.isNotEmpty()
        retainedReturn = null
        if (awaitingHandoff) {
            handoffRevision = selectionRevision
            publishedTitles.add(merged)
            handoffEvent = when (val queued = queuedHandoffs.removeFirst()) {
                is EditorHandoff.Return -> {
                    val nextReturn = EditorHandoff.Return(merged, caret)
                    retainedReturn = nextReturn
                    keepPrefix(merged.take(caret), buffered)
                    nextReturn
                }
                is EditorHandoff.Paste -> {
                    keepPrefix("", buffered)
                    EditorHandoff.Paste(rebasePastePayload(queued.payload, merged))
                }
            }
        } else {
            keepPrefix("", TextFieldValue(merged, selection))
            if (merged != modelTitle) needsDebounceAfterReconcile = true
        }
    }
    LaunchedEffect(blockId, selectionRevision) {
        val event = handoffEvent
        handoffEvent = null
        when (event) {
            is EditorHandoff.Return -> context.emit(
                "return", "title" to event.title, "caret-utf16-offset" to event.caret,
            )
            is EditorHandoff.Paste -> context.emit("paste-content", "value" to event.payload)
            null -> Unit
        }
    }

    // A reused editor must show its new block before this frame is drawn.
    if (!awaitingHandoff) {
        val blockChanged = blockId != rememberedBlockId
        rememberedBlockId = blockId
        val selectionRequested = selectionRevision != rememberedSelectionRevision
        rememberedSelectionRevision = selectionRevision
        val titleChanged = modelTitle != rememberedModelTitle
        rememberedModelTitle = modelTitle
        val acknowledged = if (blockChanged) -1 else publishedTitles.indexOf(modelTitle)
        if (acknowledged >= 0) {
            repeat(acknowledged + 1) { publishedTitles.removeAt(0) }
        }
        val hasNewerInput = selectionRequested && !blockChanged && value.let {
            it.text != modelTitle || it.composition != null
        }
        // A structural acknowledgement can change only the revision after the new block
        // is already accepting input. A caret request must not replace that text.
        val preserveNativeInput = acknowledged >= 0 && (!selectionRequested || hasNewerInput)
        if (!preserveNativeInput && (blockChanged || titleChanged || (selectionRequested && !hasNewerInput))) {
            if (titleChanged) publishedTitles.clear()
            publishedInput = null
            applyingModel = true
            cancelDebounce()
            val offset = modelCaret.coerceIn(0, modelTitle.length)
            applyNativeValue(TextFieldValue(modelTitle, TextRange(offset)))
            applyingModel = false
        }
    }
    val visibleBlockId = if (composingAcrossHandoff) blockId else rememberedBlockId

    fun publishInput(input: TextFieldValue, composing: Boolean) {
        val title = input.text
        val caret = caretOffset(input, title)
        val published = Triple(title, caret, composing)
        if (published == publishedInput ||
            (composing && publishedInput == Triple(title, caret, false)) ||
            (title == modelTitle && publishedInput == null)
        ) return
        if (publishedTitles.lastOrNull() != title) publishedTitles.add(title)
        publishedInput = published
        context.emit(if (composing) "composing-text-change" else "text-change",
            "title" to title, "caret-utf16-offset" to caret)
    }

    fun scheduleDebounce() {
        debounceJob?.cancel()
        if (awaitingHandoff || !focusEnabled) {
            debounceJob = null
            return
        }
        debounceJob = pasteScope.launch {
            delay(80)
            if (awaitingHandoff || !focusEnabled) return@launch
            val input = value
            publishInput(input, composing = input.composition != null)
        }
    }

    LaunchedEffect(focusEnabled) {
        if (focusEnabled) focusRequester.requestFocus()
        else cancelDebounce()
    }
    // When the system dismisses the IME while this editor still owns focus,
    // end the editing session so the editor toolbar doesn't stay orphaned.
    // The root host signals IME hide animations as they start. Keep an inset
    // watcher as a fallback for hosts/tests without that signal: visibility
    // itself clears too late, while the animated inset starts shrinking in the
    // first frames. Debounce input-connection flicker briefly, but keep the
    // bottom chrome transition inside the IME animation. Only fire after the
    // IME was actually shown for this editor — with a hardware keyboard it is
    // never visible.
    val ime = WindowInsets.ime
    val density = LocalDensity.current
    var dismissalEmitted by remember { mutableStateOf(false) }
    val dismissalSignal = LocalImeDismissalSignal.current
    fun emitImeDismissed() {
        cancelDebounce()
        publishInput(value, composing = false)
        context.emit("ime-dismissed")
    }
    LaunchedEffect(focusEnabled, dismissalSignal) {
        if (!focusEnabled || dismissalSignal == null) return@LaunchedEffect
        dismissalSignal.started.collect {
            if (!dismissalEmitted) {
                dismissalEmitted = true
                emitImeDismissed()
            }
        }
    }
    LaunchedEffect(focusEnabled, ime, density) {
        var imeWasVisible = false
        var shownBottom = 0
        var dismissalPending = false
        snapshotFlow { ime.getBottom(density) }.collect { bottom ->
            val hiding = imeWasVisible && bottom < shownBottom - 4
            if (bottom > 0 && !hiding) {
                imeWasVisible = true
                shownBottom = maxOf(shownBottom, bottom)
                dismissalPending = false
                dismissalEmitted = false
                return@collect
            }
            if (!hiding) return@collect
            if (dismissalPending) return@collect
            dismissalPending = true
            launch {
                delay(32)
                if (dismissalPending) {
                    imeWasVisible = false
                    shownBottom = 0
                    if (!dismissalEmitted) {
                        dismissalEmitted = true
                        emitImeDismissed()
                    }
                }
            }
        }
    }
    val inputOwner = remember { Any() }
    SideEffect {
        if (needsDebounceAfterReconcile) scheduleDebounce()
        if (focusEnabled) NativeEditorInput.register(inputOwner) {
            if (!awaitingHandoff) {
                cancelDebounce()
                publishInput(value, composing = false)
            }
        } else NativeEditorInput.unregister(inputOwner)
    }
    DisposableEffect(Unit) {
        onDispose {
            cancelDebounce()
            NativeEditorInput.unregister(inputOwner)
        }
    }

    fun submitReturn(title: String, caret: Int) {
        capturePendingInput(TextFieldValue(title, TextRange(caret)))
        val split = caret.coerceIn(0, title.length)
        if (!awaitingHandoff) retainedReturn = EditorHandoff.Return(title, split)
        // Keep the real caret at the split. The input for the next block starts there.
        keepPrefix(nativeValue.prefix + title.take(split), TextFieldValue(title.drop(split), TextRange(0)))
        if (awaitingHandoff) {
            queuedHandoffs.addLast(EditorHandoff.Return(title, caret))
            handoffSegments.addLast(PendingEditorInput(value.text, value.selection.start))
            return
        }
        cancelDebounce()
        publishedTitles.add(title)
        awaitingHandoff = true
        handoffRevision = selectionRevision
        handoffSegments.addLast(PendingEditorInput(value.text, value.selection.start))
        context.emit("return", "title" to title, "caret-utf16-offset" to caret)
    }

    fun returnAtSelection() {
        val start = value.selection.min.coerceIn(0, value.text.length)
        val end = value.selection.max.coerceIn(start, value.text.length)
        submitReturn(value.text.removeRange(start, end), start)
    }

    fun commitComposition(): Boolean {
        val current = value
        if (current.composition == null) return false
        val committed = current.copy(composition = null)
        capturePendingInput(committed)
        applyNativeValue(committed)
        if (!awaitingHandoff) scheduleDebounce()
        return true
    }

    // Gboard can mark an existing word as composing without changing the text.
    fun hasUnconfirmedComposition(): Boolean {
        val current = value
        return current.composition != null && current.text != (compositionStartText ?: observedValue.text)
    }

    fun handleEnter(event: ComposeKeyEvent): Boolean {
        if (event.key != Key.Enter && event.key != Key.NumPadEnter) return false
        if (event.type != KeyEventType.KeyDown) return false
        if (multiline && !event.isShiftPressed) return false
        val hasUnconfirmedText = hasUnconfirmedComposition()
        if (commitComposition() && hasUnconfirmedText) return true
        if (!event.isShiftPressed || code && multiline) {
            returnAtSelection()
        } else {
            val start = value.selection.min.coerceIn(0, value.text.length)
            val end = value.selection.max.coerceIn(start, value.text.length)
            val next = TextFieldValue(value.text.replaceRange(start, end, "\n"), TextRange(start + 1))
            if (awaitingHandoff) capturePendingInput(next) else scheduleDebounce()
            applyNativeValue(next)
        }
        return true
    }

    fun emitStructuralBackspace() {
        context.emit(
            "backspace",
            "title" to value.text,
            "selection-length" to 0,
        )
    }

    fun acceptValue(incoming: TextFieldValue) {
            if (incoming == observedValue) return
            val prior = observedValue
            if (incoming.composition == null) compositionStartText = null
            else if (compositionStartText == null) compositionStartText = prior.text
            if (awaitingHandoff) {
                val priorText = prior.text
                var prefix = 0
                while (prefix < priorText.length && prefix < incoming.text.length && priorText[prefix] == incoming.text[prefix]) prefix++
                var suffix = 0
                while (suffix < priorText.length - prefix && suffix < incoming.text.length - prefix &&
                    priorText[priorText.lastIndex - suffix] == incoming.text[incoming.text.lastIndex - suffix]) suffix++
                val inserted = incoming.text.substring(prefix, incoming.text.length - suffix)
                val removed = priorText.length - prefix - suffix
                if (incoming.composition == null && inserted == "\n" && removed == 0) {
                    submitReturn(priorText, prefix)
                    return
                }
                capturePendingInput(incoming)
                value = incoming
                return
            }
            val location = incoming.selection.start
            val deletion = if (incoming.composition == null && prior.selection.collapsed && location >= 0
                && prior.text.length == incoming.text.length + 1 && location < prior.text.length
                && prior.text.removeRange(location, location + 1) == incoming.text) {
                applyEmptyPairDeletion(inputPolicy, prior.text, location, 1, "")
            } else null
            val next = deletion?.let { TextFieldValue(it.first, TextRange(it.second)) } ?: incoming
            if (applyingModel) {
                value = next
                return
            }
            val textChanged = next.text != prior.text
            if (textChanged) {
                previousText = prior.text
                previousSelection = prior.selection
            }
            observedValue = next
            value = next

            if (!focusEnabled) return
            if (!textChanged) {
                if (prior.composition != next.composition ||
                    (next.selection != prior.selection &&
                        (next.composition != null || next.text != (publishedInput?.first ?: modelTitle)))
                ) {
                    scheduleDebounce()
                } else if (next.selection != prior.selection && next.selection.start >= 0) {
                    publishedInput = Triple(next.text, next.selection.start, false)
                    context.emit("caret-change", "caret-utf16-offset" to next.selection.start)
                }
                return
            }

            val title = next.text
            val caret = next.selection.start.coerceAtLeast(0)
            val newline = caret - 1
            val singleInsertion =
                title.length == previousText.length + 1 &&
                    newline >= 0 &&
                    newline < title.length &&
                    title[newline] == '\n' &&
                    title.removeRange(newline, newline + 1) == previousText
            val replacedSelection =
                !previousSelection.collapsed &&
                    previousSelection.min >= 0 &&
                    previousText.replaceRange(
                        previousSelection.min,
                        previousSelection.max,
                        "\n",
                    ) == title
            if (!multiline && next.composition == null && (singleInsertion || replacedSelection)) {
                val splitAt = if (replacedSelection) previousSelection.min else newline
                val submitted = title.removeRange(splitAt, splitAt + 1)
                val submittedCaret = splitAt.coerceIn(0, submitted.length)
                applyingModel = true
                applyNativeValue(TextFieldValue(submitted, TextRange(submittedCaret)))
                applyingModel = false
                submitReturn(submitted, submittedCaret)
            } else {
                scheduleDebounce() // schedule text-change
            }
    }

    fun submitPaste() {
        val images = AndroidBlockClipboard.imageUris(androidContext, clipboard.primaryClip)
        if (images.isNotEmpty()) {
            val importer = importPastedImage ?: return
            if (importingImages || awaitingHandoff) return
            importingImages = true
            pasteScope.launch {
                val assets = mutableListOf<JSONObject>()
                var handedOff = false
                try {
                    for (uri in images) assets.add(importer(uri))
                    if (latestBlockId == blockId && latestSelectionRevision == selectionRevision && !awaitingHandoff) {
                        val payload = JSONObject().put("assets", JSONArray(assets))
                            .put("targetBlockId", blockId).put("beforeTitle", value.text)
                            .put("selectionStart", value.selection.min)
                            .put("selectionLength", value.selection.max - value.selection.min)
                        cancelDebounce()
                        handoffRevision = selectionRevision
                        awaitingHandoff = true
                        handoffSegments.addLast(PendingEditorInput(value.text, value.selection.start))
                        context.emit("paste-content", "value" to payload.toString())
                        handedOff = true
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    LogseqDialogs.notifyError(error.message ?: "The image could not be pasted")
                } finally {
                    if (!handedOff) assets.forEach { File(it.getString("localPath")).delete() }
                    importingImages = false
                }
            }
            return
        }
        capturePendingInput(value)
        val payload = AndroidBlockClipboard.content(androidContext, value.text,
            value.selection.min, value.selection.max - value.selection.min) ?: return
        val plain = org.json.JSONObject(payload).getString("plainText")
            .replace("\r\n", "\n").replace('\r', '\n')
        val start = value.selection.min.coerceIn(0, value.text.length)
        val end = value.selection.max.coerceIn(start, value.text.length)
        value = TextFieldValue(value.text.replaceRange(start, end, plain), TextRange(start + plain.length))
        observedValue = value
        cancelDebounce()
        if (awaitingHandoff) {
            queuedHandoffs.addLast(EditorHandoff.Paste(payload))
            handoffSegments.addLast(PendingEditorInput(value.text, value.selection.start))
            return
        }
        handoffRevision = selectionRevision
        awaitingHandoff = true
        handoffSegments.addLast(PendingEditorInput(value.text, value.selection.start))
        context.emit("paste-content", "value" to payload)
    }
    val onNativeChange by rememberUpdatedState(::acceptValue)
    LaunchedEffect(fieldState) {
        snapshotFlow { nativeValue.read() }
            .collect { onNativeChange(it) }
    }
    val onSubmitPaste by rememberUpdatedState(::submitPaste)
    val completionToolbar = remember(nativeToolbar) {
        object : TextToolbar {
            override val status get() = nativeToolbar.status
            override fun hide() = nativeToolbar.hide()
            override fun showMenu(rect: Rect, onCopyRequested: (() -> Unit)?, onPasteRequested: (() -> Unit)?,
                onCutRequested: (() -> Unit)?, onSelectAllRequested: (() -> Unit)?) {
                nativeToolbar.showMenu(rect, onCopyRequested, onPasteRequested?.let { { onSubmitPaste() } },
                    onCutRequested, onSelectAllRequested)
            }
        }
    }

    CompositionLocalProvider(LocalTextToolbar provides completionToolbar) {
    Box(if (code) Modifier.background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
        .padding(12.dp).testTag("outliner.code-editor.$visibleBlockId") else Modifier) {
    val highlighted = if (code) {
        val displayTitle = if (composingAcrossHandoff) value.text else retainedReturn?.title ?: value.text
        rememberHighlightedCode(displayTitle, codeLanguage)
    } else null
    val highlightedState = rememberUpdatedState(highlighted)
    val hideHandoffPrefix = rememberUpdatedState(composingAcrossHandoff)
    val inputTransformation = remember {
        InputTransformation {
            val boundary = nativeValue.prefix.length
            if (boundary > 0) {
                if ((0 until changes.changeCount).any { changes.getOriginalRange(it).min < boundary }) {
                    revertAllChanges()
                }
                selection = TextRange(selection.start.coerceAtLeast(boundary), selection.end.coerceAtLeast(boundary))
            }
        }
    }
    val outputTransformation = remember {
        OutputTransformation {
            if (hideHandoffPrefix.value) {
                // Keep the source prefix in the IME buffer, outside its composing range.
                replace(0, minOf(nativeValue.prefix.length, length), "")
            } else {
                // Buffer edits to the next block while displaying the source row.
                retainedReturn?.let { source ->
                    val current = asCharSequence()
                    if (!current.contentEquals(source.title)) {
                        // Compose can transform a proposed edit before the input filter rejects it.
                        val preserved = if (current.startsWith(source.title.take(source.caret))) source.caret else 0
                        replace(preserved, length, source.title.drop(preserved))
                    }
                }
            }
            val styled = highlightedState.value
            if (styled != null && styled.text == asCharSequence().toString()) {
                styled.spanStyles.forEach { addStyle(it.item, it.start, it.end) }
            }
        }
    }
    OutlinerTextInput(
        state = fieldState,
        multiline = multiline,
        prefixLength = { nativeValue.prefix.length },
        prefixHidden = { hideHandoffPrefix.value },
        onEmptyBlockBackspace = {
            if (awaitingHandoff) {
                false
            } else {
                emitStructuralBackspace()
                true
            }
        },
    ) {
    BasicTextField(
        state = fieldState,
        enabled = focusEnabled,
        inputTransformation = inputTransformation,
        outputTransformation = outputTransformation,
        modifier = Modifier
            .fillMaxWidth()
            .appendTextContextMenuComponents {
                val clip = clipboard.primaryClip
                if (clip != null && clip.itemCount > 0 &&
                    (clip.description.hasMimeType("image/*") || clip.getItemAt(0).coerceToText(androidContext) != null)
                ) item(pasteKey, pasteLabel) {
                    submitPaste()
                    close()
                }
            }
            .filterTextContextMenuComponents { it.key != TextContextMenuKeys.PasteKey }
            .focusRequester(focusRequester)
            .testTag("field.outliner.block.$visibleBlockId")
            .semantics { testTagsAsResourceId = true }
            .onPreInterceptKeyBeforeSoftKeyboard { event ->
                if (event.key != Key.Enter && event.key != Key.NumPadEnter) return@onPreInterceptKeyBeforeSoftKeyboard false
                when (event.type) {
                    KeyEventType.KeyDown -> {
                        // Give the IME the whole key press when it can confirm a candidate.
                        val canIntercept = if (event.nativeKeyEvent.repeatCount == 0) {
                            preImeEnterKeys.remove(event.key)
                            !hasUnconfirmedComposition()
                        } else event.key in preImeEnterKeys
                        (canIntercept && handleEnter(event)).also { handled ->
                            if (handled) preImeEnterKeys.add(event.key)
                        }
                    }
                    KeyEventType.KeyUp -> preImeEnterKeys.remove(event.key)
                    else -> false
                }
            }
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown &&
                    ((event.key == Key.V && event.isCtrlPressed) || (event.key == Key.Insert && event.isShiftPressed))) {
                    submitPaste()
                    return@onPreviewKeyEvent true
                }
                if (handleEnter(event)) return@onPreviewKeyEvent true
                if (event.type == KeyEventType.KeyDown &&
                    event.key == Key.Backspace &&
                    value.selection.collapsed &&
                    value.selection.start == 0
                ) {
                    emitStructuralBackspace()
                    true
                } else {
                    false
                }
            },
        textStyle = outlinerBodyStyle.copy(
            color = MaterialTheme.colorScheme.onSurface,
            fontFamily = if (code) FontFamily.Monospace else outlinerBodyStyle.fontFamily,
        ),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        keyboardOptions = KeyboardOptions(
            capitalization = if (code) KeyboardCapitalization.None else KeyboardCapitalization.Sentences,
            autoCorrectEnabled = if (code) false else null,
            imeAction = if (multiline) ImeAction.Default else ImeAction.Next,
        ),
        onKeyboardAction = {
            // In an ordinary block, Next submits even if the IME is still composing.
            if (!multiline || !commitComposition()) returnAtSelection()
        },
    )
    }
    }
    }
}

private class BatchedBackspace(private val text: CharSequence) {
    var caret = text.length
        private set
    var removeEmptyBlock = false
        private set

    fun deleteBackward(length: Int, codePoints: Boolean) {
        // A delete that consumes the last character is different from one on an empty block.
        if (caret == 0) {
            if (length == 1) removeEmptyBlock = true
            return
        }
        if (codePoints) {
            repeat(length) {
                if (caret == 0) return
                caret -= Character.charCount(Character.codePointBefore(text, caret))
            }
        } else {
            caret = (caret - length).coerceAtLeast(0)
        }
    }
}

private enum class BatchComposition {
    Unchanged,
    FinishPending,
    Edited,
}

@Composable
private fun OutlinerTextInput(
    state: TextFieldState,
    multiline: Boolean,
    prefixLength: () -> Int,
    prefixHidden: () -> Boolean,
    onEmptyBlockBackspace: () -> Boolean,
    content: @Composable () -> Unit,
) {
    val acceptsNewlines = rememberUpdatedState(multiline)
    val handoffPrefixLength = rememberUpdatedState(prefixLength)
    val hidesHandoffPrefix = rememberUpdatedState(prefixHidden)
    val emptyBlockBackspace = rememberUpdatedState(onEmptyBlockBackspace)
    val interceptor = remember(state) {
        PlatformTextInputInterceptor { request, next ->
            next.startInputMethod(PlatformTextInputMethodRequest { attributes ->
                val connection = request.createInputConnection(attributes)
                object : InputConnectionWrapper(connection, false) {
                    private var batchDepth = 0
                    private val inBatch get() = batchDepth > 0
                    private var batchComposition = BatchComposition.Unchanged
                    private var batchedBackspace: BatchedBackspace? = null

                    override fun beginBatchEdit(): Boolean = super.beginBatchEdit().also { began ->
                        if (!began) return@also
                        batchDepth++
                        if (batchDepth == 1) {
                            val text = state.text
                            if (state.selection == TextRange(text.length) && state.composition == null) {
                                batchedBackspace = BatchedBackspace(text)
                            }
                        }
                    }

                    override fun endBatchEdit(): Boolean {
                        if (!inBatch) return super.endBatchEdit()
                        if (batchDepth == 1) beforeCompositionEdit()
                        val nested = super.endBatchEdit()
                        batchDepth--
                        if (!inBatch) {
                            val shouldRemoveBlock = batchedBackspace?.removeEmptyBlock == true && state.text.isEmpty()
                            batchComposition = BatchComposition.Unchanged
                            batchedBackspace = null
                            if (shouldRemoveBlock) emptyBlockBackspace.value()
                        }
                        return nested
                    }

                    private fun beforeCompositionEdit() {
                        if (batchComposition == BatchComposition.FinishPending) super.finishComposingText()
                        if (inBatch) batchComposition = BatchComposition.Edited
                    }

                    private inline fun otherEdit(action: () -> Boolean): Boolean {
                        batchedBackspace = null
                        beforeCompositionEdit()
                        return action()
                    }

                    private fun handleBackspace(beforeLength: Int, afterLength: Int, codePoints: Boolean): Boolean {
                        if (!inBatch) {
                            return beforeLength == 1 && afterLength == 0 && state.text.isEmpty() &&
                                emptyBlockBackspace.value()
                        }
                        beforeCompositionEdit()
                        // Track consecutive backward deletes against the buffer at the start of
                        // the batch. Compose applies the actual text edits when the batch ends.
                        if (afterLength == 0 && beforeLength >= 0) {
                            batchedBackspace?.deleteBackward(beforeLength, codePoints)
                        } else {
                            batchedBackspace = null
                        }
                        return false
                    }

                    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
                        handleBackspace(beforeLength, afterLength, codePoints = false) ||
                            super.deleteSurroundingText(beforeLength, afterLength)

                    override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
                        handleBackspace(beforeLength, afterLength, codePoints = true) ||
                            super.deleteSurroundingTextInCodePoints(beforeLength, afterLength)

                    // A newline from the IME is another form of the Enter key.
                    private fun handleCommittedText(text: CharSequence?): Boolean? {
                        if (text?.contentEquals("\n") != true) return null
                        if (state.composition != null) return finishComposingText()
                        if (acceptsNewlines.value) return null
                        return performEditorAction(EditorInfo.IME_ACTION_NEXT)
                    }

                    override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean = otherEdit {
                        handleCommittedText(text) ?: super.commitText(text, newCursorPosition)
                    }

                    @RequiresApi(33)
                    override fun commitText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean = otherEdit {
                        handleCommittedText(text) ?: super.commitText(text, newCursorPosition, textAttribute)
                    }

                    override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean = otherEdit {
                        super.setComposingText(text, newCursorPosition)
                    }

                    @RequiresApi(33)
                    override fun setComposingText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean = otherEdit {
                        super.setComposingText(text, newCursorPosition, textAttribute)
                    }

                    override fun finishComposingText(): Boolean {
                        if (inBatch && batchComposition != BatchComposition.Edited &&
                            hidesHandoffPrefix.value() && state.composition != null
                        ) {
                            // An IME can finish and reopen the same candidate in one transaction.
                            batchComposition = BatchComposition.FinishPending
                            return true
                        }
                        beforeCompositionEdit()
                        return super.finishComposingText()
                    }

                    @RequiresApi(34)
                    override fun replaceText(
                        start: Int, end: Int, text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?,
                    ): Boolean = otherEdit {
                        super.replaceText(start, end, text, newCursorPosition, textAttribute)
                    }

                    override fun setSelection(start: Int, end: Int): Boolean {
                        // The queued deletes have already moved the tracked caret.
                        if (start != end || start != batchedBackspace?.caret) batchedBackspace = null
                        return super.setSelection(start, end)
                    }

                    private fun updateComposingRegion(
                        start: Int, end: Int, update: (Int, Int) -> Boolean,
                    ): Boolean {
                        val offset = handoffPrefixLength.value()
                        val hidden = hidesHandoffPrefix.value()
                        val composition = state.composition
                        // Remapping visible offset zero could expand the existing region over the hidden prefix.
                        // The current range is usable until an earlier edit can change composition.
                        if (batchComposition != BatchComposition.Edited && hidden && composition != null &&
                            composition.min - offset == minOf(start, end) &&
                            composition.max - offset == maxOf(start, end)
                        ) {
                            batchedBackspace = null
                            // Reopening the same range cancels a deferred finish in this batch.
                            batchComposition = BatchComposition.Unchanged
                            return true
                        }
                        val boundary = if (hidden) 0 else offset
                        return otherEdit { update(maxOf(start, boundary), maxOf(end, boundary)) }
                    }

                    override fun setComposingRegion(start: Int, end: Int): Boolean =
                        updateComposingRegion(start, end) { boundedStart, boundedEnd ->
                            super.setComposingRegion(boundedStart, boundedEnd)
                        }

                    @RequiresApi(33)
                    override fun setComposingRegion(start: Int, end: Int, textAttribute: TextAttribute?): Boolean =
                        updateComposingRegion(start, end) { boundedStart, boundedEnd ->
                            super.setComposingRegion(boundedStart, boundedEnd, textAttribute)
                        }

                    override fun performEditorAction(editorAction: Int): Boolean = otherEdit {
                        super.performEditorAction(editorAction)
                    }

                    override fun performContextMenuAction(id: Int): Boolean = otherEdit {
                        super.performContextMenuAction(id)
                    }

                    override fun sendKeyEvent(event: KeyEvent): Boolean = otherEdit {
                        super.sendKeyEvent(event)
                    }
                }
            })
        }
    }
    InterceptPlatformTextInput(interceptor, content)
}

private fun caretOffset(value: TextFieldValue, text: String): Int =
    if (value.selection.start < 0) text.length else value.selection.start

private fun rebasePastePayload(payload: String, title: String): String {
    val fields = org.json.JSONObject(payload)
    val previous = fields.getString("beforeTitle")
    val start = (fields.getInt("selectionStart") + title.length - previous.length).coerceIn(0, title.length)
    val length = fields.getInt("selectionLength").coerceIn(0, title.length - start)
    return fields.put("beforeTitle", title).put("selectionStart", start)
        .put("selectionLength", length).toString()
}
