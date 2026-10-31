package com.logseq.app.ui.extensions

import org.json.JSONObject

internal data class EditorInputSnapshot(val text: String, val selectionStart: Int, val selectionEnd: Int = selectionStart)

internal class PendingEditorInput(initialText: String, initialCaret: Int) {
    private val edits = mutableListOf(EditorInputSnapshot(initialText, initialCaret))

    fun capture(text: String, caret: Int, selectionEnd: Int = caret) {
        val next = EditorInputSnapshot(text, caret.coerceIn(0, text.length), selectionEnd.coerceIn(0, text.length))
        if (edits.last() != next) edits.add(next)
    }

    fun rebase(title: String, caret: Int): EditorInputSnapshot {
        var canonical = title
        var canonicalCaret = caret
        var canonicalEnd = caret
        for (i in 1 until edits.size) {
            val (before, origin) = edits[i - 1]
            val (after, nextCaret, nextEnd) = edits[i]
            if (before == canonical) {
                canonical = after
                canonicalCaret = nextCaret
                canonicalEnd = nextEnd
                continue
            }
            var prefix = 0
            while (prefix < before.length && prefix < after.length && before[prefix] == after[prefix]) prefix++
            var suffix = 0
            while (suffix < before.length - prefix && suffix < after.length - prefix &&
                before[before.lastIndex - suffix] == after[after.lastIndex - suffix]) suffix++
            val oldEnd = before.length - suffix
            val newEnd = after.length - suffix
            val inserted = after.substring(prefix, newEnd)
            if (prefix == oldEnd && prefix == origin && nextCaret == newEnd && nextCaret == nextEnd) {
                canonical = canonical.replaceRange(canonicalCaret, canonicalCaret, inserted)
                canonicalCaret += inserted.length
                canonicalEnd = canonicalCaret
                continue
            }
            val indices = matchCharacters(before, origin, canonical, canonicalCaret)
            fun boundary(offset: Int): Int = when {
                offset == origin -> canonicalCaret
                offset < indices.size && indices[offset] >= 0 -> indices[offset]
                offset > 0 && indices[offset - 1] >= 0 -> indices[offset - 1] + 1
                else -> canonicalCaret
            }
            var start = boundary(prefix)
            var end = start
            var matched = false
            for (j in prefix until oldEnd) if (indices[j] >= 0) {
                if (!matched) start = indices[j]
                end = indices[j] + 1
                matched = true
            }
            val rebasedCaret = when {
                nextCaret < prefix -> boundary(nextCaret)
                nextCaret <= newEnd -> start + nextCaret - prefix
                else -> boundary(oldEnd + nextCaret - newEnd) + inserted.length - (end - start)
            }
            canonical = canonical.replaceRange(start, end, inserted)
            canonicalCaret = rebasedCaret.coerceIn(0, canonical.length)
            canonicalEnd = canonicalCaret
            if (nextCaret != nextEnd) {
                val selected = matchCharacters(after, nextCaret, canonical, canonicalCaret)
                var first = -1
                var last = -1
                for (j in minOf(nextCaret, nextEnd) until maxOf(nextCaret, nextEnd)) if (selected[j] >= 0) {
                    if (first < 0) first = selected[j]
                    last = selected[j] + 1
                }
                if (first >= 0) {
                    canonicalCaret = if (nextCaret < nextEnd) first else last
                    canonicalEnd = if (nextCaret < nextEnd) last else first
                }
            }
        }
        return EditorInputSnapshot(canonical, canonicalCaret, canonicalEnd)
    }

    // Anchor UTF-16 offsets at the handoff caret while allowing canonical markup around native text.
    private fun matchCharacters(before: String, origin: Int, title: String, caret: Int): IntArray {
        val positions = title.indices.groupBy { title[it] }
        val indices = IntArray(before.length) { -1 }
        fun locate(character: Char, limit: Int, backwards: Boolean): Int {
            val choices = positions[character] ?: return -1
            val found = choices.binarySearch(limit)
            val index = if (found >= 0) found else if (backwards) -found - 2 else -found - 1
            return choices.getOrNull(index) ?: -1
        }
        var limit = caret - 1
        for (i in origin - 1 downTo 0) {
            indices[i] = locate(before[i], limit, true)
            if (indices[i] >= 0) limit = indices[i] - 1
        }
        limit = caret
        for (i in origin until before.length) {
            indices[i] = locate(before[i], limit, false)
            if (indices[i] >= 0) limit = indices[i] + 1
        }
        return indices
    }
}

internal fun applyEmptyPairDeletion(policy: String, text: String, location: Int, length: Int, replacement: String): Pair<String, Int>? {
    if (replacement.isNotEmpty() || length != 1) return null
    val rules = runCatching { JSONObject(policy).optJSONArray("emptyPairs") }.getOrNull() ?: return null
    for (i in 0 until rules.length()) {
        val rule = rules.optJSONObject(i) ?: continue
        val pattern = rule.optString("text")
        val offset = rule.optInt("deleteOffset", -1)
        if (pattern.length < 2 || offset !in pattern.indices || location < offset) continue
        val start = location - offset
        if (start + pattern.length <= text.length && text.startsWith(pattern, start)) {
            return text.removeRange(start, start + pattern.length) to start
        }
    }
    return null
}
