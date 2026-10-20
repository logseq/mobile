package com.logseq.app.ui.extensions

import org.json.JSONObject

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
