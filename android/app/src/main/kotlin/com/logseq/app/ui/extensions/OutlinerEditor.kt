package com.logseq.app.ui.extensions

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.geometry.Rect
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuKeys
import androidx.compose.foundation.text.contextmenu.builder.item
import androidx.compose.foundation.text.contextmenu.modifier.appendTextContextMenuComponents
import androidx.compose.foundation.text.contextmenu.modifier.filterTextContextMenuComponents
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import dev.lui.LuiExtensionContext
import kotlinx.coroutines.delay

// Port of the former _OutlinerEditor Dart implementation.
//
// The block title/caret are owned by the OCaml core. Local edits emit
// text-change (debounced 80ms), the block-creation key emits return, backspace at offset 0
// emits a structural backspace. Model acknowledgements echo locally
// published titles — those updates are swallowed so typing is never
// reverted mid-keystroke.
@Composable
internal fun OutlinerEditor(context: LuiExtensionContext) {
    val blockId = context.string("block-id") ?: ""
    val modelTitle = context.string("title") ?: ""
    val modelCaret = context.int("caret-utf16-offset") ?: -1
    val selectionRevision = context.int("selection-revision") ?: 0
    val inputPolicy = context.string("input-policy") ?: "{}"
    val focusEnabled = context.bool("focus-enabled") == true
    val code = remember(inputPolicy) { runCatching { org.json.JSONObject(inputPolicy).optBoolean("code") }.getOrDefault(false) }
    val multiline = remember(inputPolicy) { runCatching { org.json.JSONObject(inputPolicy).optBoolean("multiline") }.getOrDefault(false) }

    val focusRequester = remember { FocusRequester() }
    var value by remember {
        mutableStateOf(
            TextFieldValue(modelTitle, TextRange(modelCaret.coerceAtLeast(0)))
        )
    }
    var observedText by remember { mutableStateOf(value.text) }
    var previousText by remember { mutableStateOf(modelTitle) }
    var previousSelection by remember { mutableStateOf(value.selection) }
    var rememberedModelTitle by remember { mutableStateOf(modelTitle) }
    var rememberedModelCaret by remember { mutableIntStateOf(modelCaret) }
    var rememberedSelectionRevision by remember { mutableIntStateOf(selectionRevision) }
    var rememberedBlockId by remember { mutableStateOf(blockId) }
    var awaitingHandoff by remember { mutableStateOf(false) }
    // Each segment contains typing after one queued Enter, preserving input order.
    val handoffSegments = remember { ArrayDeque<String>() }
    var applyingModel by remember { mutableStateOf(false) }
    var debounceSeq by remember { mutableIntStateOf(0) }
    var pasteRevision by remember { mutableStateOf<Int?>(null) }
    val nativeToolbar = LocalTextToolbar.current
    val androidContext = LocalContext.current
    val clipboard = remember(androidContext) {
        androidContext.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    }
    val pasteKey = remember { Any() }
    val publishedTitles = remember { mutableStateListOf<String>() }
    var handoffReturn by remember { mutableStateOf<Pair<String, Int>?>(null) }

    // Reconcile a structural handoff in this composition, so the IME sees the
    // new text, caret and identity together instead of waiting another frame.
    val pasteAcknowledged = pasteRevision != null && selectionRevision != pasteRevision
    if (awaitingHandoff && (blockId != rememberedBlockId || pasteAcknowledged)) {
        pasteRevision = null
        val typing = handoffSegments.removeFirstOrNull().orEmpty()
        val offset = modelCaret.coerceIn(0, modelTitle.length)
        val merged = modelTitle.substring(0, offset) + typing + modelTitle.substring(offset)
        val caret = offset + typing.length
        rememberedBlockId = blockId
        rememberedModelTitle = modelTitle
        rememberedModelCaret = modelCaret
        rememberedSelectionRevision = selectionRevision
        publishedTitles.clear()
        value = TextFieldValue(merged, TextRange(caret))
        observedText = merged
        awaitingHandoff = handoffSegments.isNotEmpty()
        if (awaitingHandoff) {
            publishedTitles.add(merged)
            handoffReturn = merged to caret
        } else if (typing.isNotEmpty()) {
            debounceSeq++
        }
    }
    LaunchedEffect(blockId) {
        handoffReturn?.let { (title, caret) ->
            handoffReturn = null
            context.emit("return", "title" to title, "caret-utf16-offset" to caret)
        }
    }

    // Model → field sync (didUpdateWidget equivalent).
    LaunchedEffect(blockId, modelTitle, modelCaret, selectionRevision) {
        val blockChanged = blockId != rememberedBlockId
        if (awaitingHandoff && !blockChanged) return@LaunchedEffect
        rememberedBlockId = blockId
        val selectionRequested = selectionRevision != rememberedSelectionRevision
        rememberedSelectionRevision = selectionRevision
        val titleChanged = modelTitle != rememberedModelTitle
        val caretChanged = modelCaret != rememberedModelCaret
        rememberedModelTitle = modelTitle
        rememberedModelCaret = modelCaret
        val acknowledged = if (blockChanged) -1 else publishedTitles.indexOf(modelTitle)
        if (acknowledged >= 0) {
            repeat(acknowledged + 1) { publishedTitles.removeAt(0) }
            if (!selectionRequested) return@LaunchedEffect
        }
        // Acknowledging our caret must preserve native selection and IME composition.
        val externalCaret = caretChanged && modelCaret != value.selection.start
        if (blockChanged || selectionRequested || titleChanged || (externalCaret && value.text == modelTitle)) {
            if (titleChanged) publishedTitles.clear()
            applyingModel = true
            debounceSeq++
            val offset = modelCaret.coerceIn(0, modelTitle.length)
            value = TextFieldValue(modelTitle, TextRange(offset))
            observedText = modelTitle
            applyingModel = false
        }
    }

    LaunchedEffect(focusEnabled) { if (focusEnabled) focusRequester.requestFocus() }
    // Debounced text-change emission, cancelled by the next edit.
    LaunchedEffect(debounceSeq) {
        if (debounceSeq == 0 || awaitingHandoff || value.composition != null) return@LaunchedEffect
        delay(80)
        val title = value.text
        publishedTitles.add(title)
        context.emit(
            "text-change",
            "title" to title,
            "caret-utf16-offset" to caretOffset(value, title),
        )
    }
    DisposableEffect(Unit) { onDispose { debounceSeq++ } }

    fun submitReturn(title: String, caret: Int) {
        if (awaitingHandoff) {
            handoffSegments.addLast("")
            return
        }
        debounceSeq++
        publishedTitles.add(title)
        awaitingHandoff = true
        handoffSegments.addLast("")
        context.emit("return", "title" to title, "caret-utf16-offset" to caret)
    }

    fun returnAtSelection() {
        val start = value.selection.min.coerceIn(0, value.text.length)
        val end = value.selection.max.coerceIn(start, value.text.length)
        submitReturn(value.text.removeRange(start, end), start)
    }

    fun emitStructuralBackspace() {
        context.emit(
            "backspace",
            "title" to value.text,
            "selection-length" to 0,
        )
    }

    fun acceptValue(incoming: TextFieldValue) {
            if (awaitingHandoff) {
                val prior = value.text
                var prefix = 0
                while (prefix < prior.length && prefix < incoming.text.length && prior[prefix] == incoming.text[prefix]) prefix++
                var suffix = 0
                while (suffix < prior.length - prefix && suffix < incoming.text.length - prefix &&
                    prior[prior.lastIndex - suffix] == incoming.text[incoming.text.lastIndex - suffix]) suffix++
                val inserted = incoming.text.substring(prefix, incoming.text.length - suffix)
                val removed = prior.length - prefix - suffix
                if (inserted == "\n" && removed == 0) {
                    handoffSegments.addLast("")
                } else if (inserted.isNotEmpty() || removed > 0) {
                    val last = handoffSegments.removeLastOrNull().orEmpty()
                    handoffSegments.addLast(last.dropLast(removed.coerceAtMost(last.length)) + inserted)
                }
                value = incoming
                observedText = incoming.text
                return
            }
            val location = incoming.selection.start
            val deletion = if (incoming.composition == null && value.selection.collapsed && location >= 0
                && value.text.length == incoming.text.length + 1 && location < value.text.length
                && value.text.removeRange(location, location + 1) == incoming.text) {
                applyEmptyPairDeletion(inputPolicy, value.text, location, 1, "")
            } else null
            val next = deletion?.let { TextFieldValue(it.first, TextRange(it.second)) } ?: incoming
            if (applyingModel) {
                value = next
                return
            }
            val textChanged = next.text != observedText
            if (textChanged) {
                previousText = observedText
                previousSelection = value.selection
            }
            observedText = next.text
            val prior = value
            value = next

            if (!textChanged && next.selection != prior.selection && next.selection.start >= 0) {
                context.emit(
                    "caret-change",
                    "caret-utf16-offset" to next.selection.start,
                )
                return
            }
            if (!textChanged) {
                if (prior.composition != null && next.composition == null) debounceSeq++
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
                    previousSelection.start >= 0 &&
                    previousText.replaceRange(
                        previousSelection.start,
                        previousSelection.end,
                        "\n",
                    ) == title
            if (!multiline && (singleInsertion || replacedSelection)) {
                val splitAt = if (replacedSelection) previousSelection.start else newline
                val submitted = title.removeRange(splitAt, splitAt + 1)
                val submittedCaret = splitAt.coerceIn(0, submitted.length)
                applyingModel = true
                value = TextFieldValue(submitted, TextRange(submittedCaret))
                observedText = submitted
                applyingModel = false
                submitReturn(submitted, submittedCaret)
            } else {
                debounceSeq++ // schedule text-change
            }
    }

    fun submitPaste() {
        val payload = com.logseq.app.AndroidBlockClipboard.content(androidContext, value.text,
            value.selection.min, value.selection.max - value.selection.min) ?: return
        debounceSeq++
        pasteRevision = selectionRevision
        awaitingHandoff = true
        handoffSegments.addLast("")
        context.emit("paste-content", "value" to payload)
    }
    val completionToolbar = remember(nativeToolbar, value, selectionRevision) {
        object : TextToolbar {
            override val status get() = nativeToolbar.status
            override fun hide() = nativeToolbar.hide()
            override fun showMenu(rect: Rect, onCopyRequested: (() -> Unit)?, onPasteRequested: (() -> Unit)?,
                onCutRequested: (() -> Unit)?, onSelectAllRequested: (() -> Unit)?) {
                nativeToolbar.showMenu(rect, onCopyRequested, onPasteRequested?.let { { submitPaste() } },
                    onCutRequested, onSelectAllRequested)
            }
        }
    }

    CompositionLocalProvider(LocalTextToolbar provides completionToolbar) {
    Box(if (code) Modifier.background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
        .padding(12.dp).testTag("outliner.code-editor.$rememberedBlockId") else Modifier) {
    BasicTextField(
        value = value,
        onValueChange = ::acceptValue,
        modifier = Modifier
            .fillMaxWidth()
            .appendTextContextMenuComponents {
                val clip = clipboard.primaryClip
                val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(androidContext)?.toString() else null
                if (text != null) item(pasteKey, androidContext.getString(android.R.string.paste)) {
                    submitPaste()
                    close()
                }
            }
            .filterTextContextMenuComponents { it.key != TextContextMenuKeys.PasteKey }
            .focusRequester(focusRequester)
            .testTag("field.outliner.block.$rememberedBlockId")
            .semantics { testTagsAsResourceId = true }
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown &&
                    ((event.key == Key.V && event.isCtrlPressed) || (event.key == Key.Insert && event.isShiftPressed))) {
                    submitPaste()
                    return@onPreviewKeyEvent true
                }
                if (event.type == KeyEventType.KeyDown && event.key == Key.Enter && event.isShiftPressed) {
                    if (code && multiline) {
                        returnAtSelection()
                        return@onPreviewKeyEvent true
                    }
                    val start = value.selection.min.coerceIn(0, value.text.length)
                    val end = value.selection.max.coerceIn(start, value.text.length)
                    val title = value.text.replaceRange(start, end, "\n")
                    if (awaitingHandoff) {
                        val last = handoffSegments.removeLastOrNull().orEmpty()
                        handoffSegments.addLast(last + "\n")
                    } else {
                        value = TextFieldValue(title, TextRange(start + 1))
                        observedText = title
                        debounceSeq++
                    }
                    true
                } else if (!multiline && event.type == KeyEventType.KeyDown && event.key == Key.Enter) {
                    // Handle hardware Enter before the IME can batch several keys into pasted text.
                    returnAtSelection()
                    true
                } else if (event.type == KeyEventType.KeyDown &&
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
        textStyle = MaterialTheme.typography.bodyLarge.copy(
            color = MaterialTheme.colorScheme.onSurface,
            // Match iOS `.body` (17pt, ~22pt leading).
            fontSize = 17.sp,
            fontFamily = if (code) FontFamily.Monospace else FontFamily.Default,
            lineHeight = 22.sp,
        ),
        keyboardOptions = KeyboardOptions(
            capitalization = if (code) KeyboardCapitalization.None else KeyboardCapitalization.Sentences,
            autoCorrectEnabled = if (code) false else null,
            imeAction = if (multiline) ImeAction.Default else ImeAction.Next,
        ),
        keyboardActions = KeyboardActions(onNext = { returnAtSelection() }),
    )
    }
    }
}

private fun caretOffset(value: TextFieldValue, text: String): Int =
    if (value.selection.start < 0) text.length else value.selection.start
