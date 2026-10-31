package com.logseq.app.runtime

import dev.lui.LuiEvent

internal object NativeEditorInput {
    private var owner: Any? = null
    private var pending: (() -> Unit)? = null

    fun register(owner: Any, flush: () -> Unit) {
        this.owner = owner
        pending = flush
    }

    fun unregister(owner: Any) {
        if (this.owner === owner) {
            this.owner = null
            pending = null
        }
    }

    fun flush() { pending?.invoke() }
}

// Kotlin port of the former lui_dispatch.dart: LUI events → native
// bridge calls, including the extension (text, value) extraction the OCaml
// side reinterprets by identifier/name.
internal fun dispatchLuiEvent(event: LuiEvent, native: LogseqNativeBridge) {
    when (event) {
        is LuiEvent.Appear -> native.appear(event.node)
        is LuiEvent.Press -> {
            NativeEditorInput.flush()
            native.press(event.node)
        }
        is LuiEvent.LongPress -> native.longPress(event.node)
        is LuiEvent.DoublePress -> native.doublePress(event.node)
        is LuiEvent.Change -> native.change(event.node)
        is LuiEvent.Submit -> native.submit(event.node)
        is LuiEvent.Dismiss -> native.dismiss(event.node)
        is LuiEvent.TextChanged -> native.textChanged(event.node, event.text)
        is LuiEvent.ToggleChanged -> native.toggleChanged(event.node, event.checked)
        is LuiEvent.ValueChanged -> native.valueChanged(event.node, event.value)
        is LuiEvent.Picked -> native.picked(event.node, event.payload)
        is LuiEvent.VisibleRange -> native.visibleRange(event.node, event.first, event.last)
        is LuiEvent.ScrollCompleted ->
            native.scrollCompleted(event.node, event.token, event.outcome)
        is LuiEvent.Extension -> native.extensionEvent(
            event.node,
            event.identifier,
            event.name,
            extensionText(event.values),
            extensionValue(event.values),
        )
        // The Logseq core ABI exports no pointer-level, context-menu,
        // press-modifier, or load entries (see
        // shared/native/logseq_core_ffi.h), so these events are
        // dropped here — matching the upstream dispatchToBridge's
        // treatment of events with no mobile export.
        is LuiEvent.PressModifiers,
        is LuiEvent.PressDetail,
        is LuiEvent.PointerDown,
        is LuiEvent.PointerUp,
        is LuiEvent.PointerEnter,
        is LuiEvent.PointerLeave,
        is LuiEvent.ContextMenuPress,
        is LuiEvent.Load,
        -> Unit
    }
}

internal fun extensionText(values: Map<String, Any?>): String {
    for (key in listOf("uuid", "title", "query", "value", "payload")) {
        (values[key] as? String)?.let { return it }
    }
    return (values["offset"] as? Number)?.toLong()?.toString() ?: ""
}

internal fun extensionValue(values: Map<String, Any?>): Long {
    for (key in listOf("caret-utf16-offset", "selection-length", "count", "width")) {
        (values[key] as? Number)?.let { return it.toLong() }
    }
    return when (values["placement"]) {
        "before" -> 0
        "inside" -> 1
        "after" -> 2
        else -> 0
    }
}
