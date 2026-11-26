package com.logseq.logseq.runtime

import dev.lui.LuiBackend
import dev.lui.LuiNodeKind
import dev.lui.LuiPatchBatch
import dev.lui.LuiPatchOp
import dev.lui.LuiWireValue
import org.json.JSONArray
import org.json.JSONObject

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
// The app supplies defaults for button alignment and menu item icon colors.
internal class LuiPatchFilter(private val backend: LuiBackend) {
    private val ignoredProperties = mutableSetOf<Pair<Long, String>>()
    private var snapshotGeneration = 0

    private data class MenuAppearance(var foreground: String?, var destructive: Boolean, var enabled: Boolean) {
        fun defaultForeground(): String? = when {
            foreground != null -> null
            !enabled -> "menu-disabled-foreground"
            destructive -> "menu-destructive-foreground"
            else -> "menu-foreground"
        }
    }

    fun applyJson(patch: String): LuiPatchBatch = apply(LuiPatchBatch.parse(patch))

    /** Apply a batch that was parsed off the main thread. */
    fun apply(document: LuiPatchBatch): LuiPatchBatch = apply(document, snapshotSource = null)

    fun applySnapshotJson(patch: String): LuiPatchBatch = applyJson(patch, snapshot = true)

    private fun applyJson(patch: String, snapshot: Boolean): LuiPatchBatch =
        apply(LuiPatchBatch.parse(patch), patch.takeIf { snapshot })

    // A snapshot keeps its source JSON so the filtered ops can be re-encoded.
    private fun apply(document: LuiPatchBatch, snapshotSource: String?): LuiPatchBatch {
        val snapshot = snapshotSource != null
        if (!snapshot && document.generation <= snapshotGeneration) return document
        val createdKinds = mutableMapOf<Long, LuiNodeKind>()
        val nextIgnored = if (snapshot) hashSetOf() else HashSet(ignoredProperties)
        val compatible = ArrayList<LuiPatchOp>(document.ops.size)
        val sourceOps = if (snapshot) JSONObject(snapshotSource).getJSONArray("ops") else null
        val snapshotOps = if (snapshot) JSONArray() else null
        val menuAppearance = mutableMapOf<Long, MenuAppearance>()

        fun appendString(id: Long, property: String, value: String) {
            compatible.add(LuiPatchOp.SetProp(id, property, LuiWireValue.Str(value)))
            snapshotOps?.put(JSONObject().put("op", "set-prop").put("id", id)
                .put("property", property).put("value", value))
        }

        fun updateMenuAppearance(id: Long, property: String, value: LuiWireValue?): String? {
            if (property != "foreground" && property != "variant" && property != "enabled") return null
            val node = if (id in createdKinds) null else backend.node(id)
            if ((createdKinds[id] ?: node?.kind) != LuiNodeKind.menuItem) return null
            val appearance = menuAppearance.getOrPut(id) {
                val previous = node?.properties.orEmpty()
                val foreground = previous["foreground"]?.stringValue
                    ?.takeUnless { it.isBlank() || it in menuForegroundDefaults }
                MenuAppearance(foreground, previous["variant"]?.stringValue == "destructive",
                    enabled = previous["enabled"]?.scalarValue != false)
            }
            when (property) {
                "foreground" -> appearance.foreground = value?.stringValue?.takeUnless(String::isBlank)
                "variant" -> appearance.destructive = value?.stringValue == "destructive"
                "enabled" -> appearance.enabled = value?.scalarValue != false
            }
            return appearance.defaultForeground()
        }

        for ((index, operation) in document.ops.withIndex()) {
            var menuDefault: Pair<Long, String>? = null
            when (operation) {
                is LuiPatchOp.CreateNode -> {
                    createdKinds[operation.id] = operation.kind
                    if (operation.kind == LuiNodeKind.menuItem) {
                        val appearance = MenuAppearance(null, destructive = false, enabled = true)
                        menuAppearance[operation.id] = appearance
                        menuDefault = operation.id to checkNotNull(appearance.defaultForeground())
                    }
                }
                is LuiPatchOp.DropNode -> {
                    createdKinds.remove(operation.id)
                    menuAppearance.remove(operation.id)
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
                        snapshotOps?.put(sourceOps!!.get(index))
                        appendString(operation.id, "text-alignment", "center")
                        continue
                    }
                    updateMenuAppearance(operation.id, operation.property, operation.value)?.let {
                        menuDefault = operation.id to it
                    }
                }
                is LuiPatchOp.RemoveProp -> {
                    if (nextIgnored.remove(operation.id to operation.property)) continue
                    updateMenuAppearance(operation.id, operation.property, null)?.let {
                        menuDefault = operation.id to it
                    }
                }
                else -> Unit
            }
            compatible.add(operation)
            snapshotOps?.put(sourceOps!!.get(index))
            menuDefault?.let { (id, value) -> appendString(id, "foreground", value) }
        }

        val batch = LuiPatchBatch(document.generation, compatible)
        val applied = if (snapshot) backend.applySnapshot(JSONObject()
            .put("generation", document.generation).put("ops", snapshotOps).toString())
            else backend.applyBatch(batch)
        check(applied) { "Could not apply UI update: ${backend.lastError}" }
        // detach-subtree can remove descendants without individual drop ops.
        // Retain only live hints instead of copying historical node metadata.
        nextIgnored.removeIf { backend.nodeKind(it.first) == null }
        ignoredProperties.clear()
        ignoredProperties.addAll(nextIgnored)
        if (snapshot) snapshotGeneration = document.generation
        return batch
    }

    companion object {
        private val menuForegroundDefaults = setOf("menu-foreground", "menu-destructive-foreground", "menu-disabled-foreground")

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
