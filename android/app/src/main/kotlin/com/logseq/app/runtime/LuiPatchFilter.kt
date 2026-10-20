package com.logseq.app.runtime

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
// `size: icon` on buttons additionally synthesizes text-alignment:center
// so the glyph centers in the touch target.
internal class LuiPatchFilter(
    private val apply: (String) -> Unit,
) {
    private val nodeKinds = mutableMapOf<Long, String>()
    private val ignoredProperties = mutableSetOf<String>()

    fun applyJson(patch: String) {
        val document = JSONObject(patch)
        val operations = document.getJSONArray("ops")
        val nextNodeKinds = HashMap(nodeKinds)
        val nextIgnored = HashSet(ignoredProperties)
        val compatible = JSONArray()

        for (index in 0 until operations.length()) {
            val operation = operations.getJSONObject(index)
            val name = operation.getString("op")
            val id = if (operation.has("id")) operation.getLong("id") else null
            when {
                name == "create-node" && id != null ->
                    nextNodeKinds[id] = operation.getString("kind")
                name == "drop-node" && id != null -> {
                    nextNodeKinds.remove(id)
                    nextIgnored.removeIf { it.startsWith("$id:") }
                }
                name == "set-prop" && id != null -> {
                    val property = operation.getString("property")
                    val key = "$id:$property"
                    if (isUnsupportedPresentationHint(
                            kind = nextNodeKinds[id],
                            property = property,
                            value = operation.opt("value"),
                        )
                    ) {
                        nextIgnored.add(key)
                        continue
                    }
                    nextIgnored.remove(key)
                    if (property == "size" &&
                        operation.opt("value") == "icon" &&
                        nextNodeKinds[id] in setOf("button", "toggle-button")
                    ) {
                        compatible.put(operation)
                        compatible.put(
                            JSONObject()
                                .put("op", "set-prop")
                                .put("id", id)
                                .put("property", "text-alignment")
                                .put("value", "center")
                        )
                        continue
                    }
                }
                name == "remove-prop" && id != null -> {
                    val property = operation.getString("property")
                    if (nextIgnored.remove("$id:$property")) continue
                }
            }
            compatible.put(operation)
        }

        apply(document.put("ops", compatible).toString())
        nodeKinds.clear()
        nodeKinds.putAll(nextNodeKinds)
        ignoredProperties.clear()
        ignoredProperties.addAll(nextIgnored)
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
