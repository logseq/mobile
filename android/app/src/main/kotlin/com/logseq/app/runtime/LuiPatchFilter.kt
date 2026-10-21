package com.logseq.app.runtime

import dev.lui.LuiBackend
import dev.lui.LuiNodeKind
import dev.lui.LuiPatchBatch
import dev.lui.LuiPatchOp
import dev.lui.LuiWireValue

// Kotlin port of the former Dart patch applier.
//
// Filters patch ops for presentation hints the Compose backend does not
// (or must not) honor — same drop rules as the Dart applier so core
// views keep working unmodified:
//   - container-relative-frame(-inset): always dropped
//   - padding-horizontal/vertical on unsupported avatar/tooltip metadata
//   - style-class on dialog/sheet
//   - icon-placement unless leading/trailing on (toggle-)button
//   - role unless "treeitem" on row/column/panel/card/box/list-item
// `size: icon` on buttons additionally synthesizes text-alignment:center
// so the glyph centers in the touch target.
internal class LuiPatchFilter(private val backend: LuiBackend) {
    private val ignoredProperties = mutableSetOf<Pair<Long, String>>()

    fun applyJson(patch: String): LuiPatchBatch {
        val document = LuiPatchBatch.parse(patch)
        val createdKinds = mutableMapOf<Long, LuiNodeKind>()
        val nextIgnored = HashSet(ignoredProperties)
        val compatible = ArrayList<LuiPatchOp>(document.ops.size)

        for (operation in document.ops) {
            when (operation) {
                is LuiPatchOp.CreateNode -> createdKinds[operation.id] = operation.kind
                is LuiPatchOp.DropNode -> {
                    createdKinds.remove(operation.id)
                    nextIgnored.removeIf { it.first == operation.id }
                }
                is LuiPatchOp.SetProp -> {
                    val kind = (createdKinds[operation.id] ?: backend.nodeKind(operation.id))?.wireName
                    val key = operation.id to operation.property
                    if (isUnsupportedPresentationHint(kind, operation.property, operation.value.scalarValue)) {
                        nextIgnored.add(key)
                        continue
                    }
                    nextIgnored.remove(key)
                    if (operation.property == "size" && operation.value.stringValue == "icon" &&
                        kind in setOf("button", "toggle-button")) {
                        compatible.add(operation)
                        compatible.add(LuiPatchOp.SetProp(operation.id, "text-alignment", LuiWireValue.Str("center")))
                        continue
                    }
                }
                is LuiPatchOp.RemoveProp -> {
                    if (nextIgnored.remove(operation.id to operation.property)) continue
                }
                else -> Unit
            }
            compatible.add(operation)
        }

        val batch = LuiPatchBatch(document.generation, compatible)
        check(backend.applyBatch(batch)) { "Could not apply UI update: ${backend.lastError}" }
        // detach-subtree can remove descendants without individual drop ops.
        // Retain only live hints instead of copying historical node metadata.
        nextIgnored.removeIf { backend.nodeKind(it.first) == null }
        ignoredProperties.clear()
        ignoredProperties.addAll(nextIgnored)
        return batch
    }

    companion object {
        fun isUnsupportedPresentationHint(
            kind: String?,
            property: String,
            value: Any?,
        ): Boolean = when (property) {
            "container-relative-frame", "container-relative-frame-inset" -> true
            "padding-horizontal", "padding-vertical" ->
                kind in setOf("avatar", "tooltip")
            "style-class" -> kind == "dialog" || kind == "sheet"
            "icon-placement" ->
                (kind != "button" && kind != "toggle-button") ||
                    (value != "leading" && value != "trailing")
            "role" ->
                value != "treeitem" ||
                    kind !in setOf("row", "column", "panel", "card", "box", "list-item")
            else -> false
        }
    }
}
