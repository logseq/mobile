package com.logseq.logseq.runtime

import org.json.JSONObject

// Kotlin port of the former android_outliner_commands.dart: decodes the
// outlinerCommands batch inside each core response and replays the
// platform-side commands (clipboard, haptics, attachment pickers, delete
// confirmation) exactly once per revision.
internal data class OutlinerPlatformCommand(
    val type: String,
    val style: String? = null,
    val text: String? = null,
    val uuid: String? = null,
    val uuids: List<String> = emptyList(),
) {
    companion object {
        fun fromJson(value: JSONObject): OutlinerPlatformCommand {
            val uuids = value.optJSONArray("uuids")
            return OutlinerPlatformCommand(
                type = value.optString("type"),
                style = value.optString("style").takeIf(String::isNotEmpty),
                text = value.optString("text").takeIf(String::isNotEmpty),
                uuid = value.optString("uuid").takeIf(String::isNotEmpty),
                uuids = uuids?.let { array ->
                    (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
                } ?: emptyList(),
            )
        }
    }
}

internal data class OutlinerPlatformCommandBatch(
    val revision: Long,
    val graphName: String,
    val commands: List<OutlinerPlatformCommand>,
    val selectedBlockIds: List<String> = emptyList(),
)

internal class OutlinerPlatformCommandDispatcher(
    private val onBatch: suspend (OutlinerPlatformCommandBatch) -> Unit,
) {
    private var lastRevision = 0L

    suspend fun deliver(response: String) {
        val batch = decode(response) ?: return
        if (batch.revision <= lastRevision) return
        lastRevision = batch.revision
        if (batch.commands.isNotEmpty()) onBatch(batch)
    }

    companion object {
        fun decode(response: String): OutlinerPlatformCommandBatch? {
            val decoded = try {
                JSONObject(response)
            } catch (_: Throwable) {
                return null
            }
            if (!decoded.optBoolean("ok")) return null
            val result = decoded.optJSONObject("result") ?: return null
            if (!result.has("outlinerCommandRevision") || !result.has("outlinerCommands")) {
                return null
            }
            val values = result.optJSONArray("outlinerCommands") ?: return null
            val selected = result.optJSONObject("outlinerState")
                ?.optJSONArray("selectedBlockIds")
            return OutlinerPlatformCommandBatch(
                revision = result.getLong("outlinerCommandRevision"),
                graphName = result.optString("graphName"),
                commands = (0 until values.length())
                    .mapNotNull { values.optJSONObject(it) }
                    .map(OutlinerPlatformCommand::fromJson)
                    .filter { it.type.isNotEmpty() },
                selectedBlockIds = selected?.let { array ->
                    (0 until array.length())
                        .mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
                } ?: emptyList(),
            )
        }
    }
}
