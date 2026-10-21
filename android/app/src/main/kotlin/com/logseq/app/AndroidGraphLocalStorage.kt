package com.logseq.app

import java.io.File
import java.net.URLEncoder
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

internal object AndroidGraphLocalStorage {
    private fun encodedId(id: String) = URLEncoder.encode(id, "UTF-8")
        .replace("+", "%20").replace(".", "%2E").replace("*", "%2A")

    private fun folderName(name: String): String {
        val prefix = StringBuilder()
        var byteCount = 0
        val scalars = name.codePoints().iterator()
        while (scalars.hasNext()) {
            val scalar = scalars.nextInt()
            val safe = if (Character.isISOControl(scalar) || Character.isWhitespace(scalar) || Character.isSpaceChar(scalar)
                || scalar in listOf(47, 92, 58)) "_"
                else String(Character.toChars(scalar))
            if (safe == "_" && prefix.endsWith("_")) continue
            val size = safe.toByteArray(Charsets.UTF_8).size
            if (byteCount + size > 120) break
            prefix.append(safe)
            byteCount += size
        }
        return prefix.toString().trim { it.isWhitespace() || it == '.' || it == '_' }.ifEmpty { "Graph" }
    }

    fun directory(graphs: File, graphId: String, graphName: String = "Graph"): File {
        val id = encodedId(graphId)
        graphs.listFiles().orEmpty().filter { it.isDirectory && (it.name.endsWith("-$id") || it.name.endsWith(" - $id")) }
            .sortedBy { it.name }.firstOrNull()?.let { return it }
        val legacy = File(graphs, id)
        if (legacy.isDirectory) return legacy
        return File(graphs, "${folderName(graphName)}-$id")
    }

    // Resolve before opening database handles; existing named folders remain stable after graph renames.
    fun prepare(graphs: File, graphId: String, graphName: String): File {
        val existing = directory(graphs, graphId, graphName)
        if (existing.name.endsWith("-${encodedId(graphId)}") && existing.name.none { it.isWhitespace() }) {
            check(existing.isDirectory || existing.mkdirs()) { "Could not create graph directory: $existing" }
            return existing
        }
        val destination = File(graphs, "${folderName(graphName)}-${encodedId(graphId)}")
        check(existing.renameTo(destination)) { "Could not migrate graph directory: $existing" }
        return destination
    }

    // The checkpoint owns graph identity; names and UUIDs may both contain hyphens.
    fun localGraphIds(graphs: File): List<String> = graphs.listFiles().orEmpty()
        .filter { it.isDirectory && File(it, "graph.sqlite").isFile && File(it, "sync.checkpoint").isFile }
        .mapNotNull { directory ->
            runCatching {
                when (val checkpoint = JSONTokener(File(directory, "sync.checkpoint").readText()).nextValue()) {
                    is JSONObject -> checkpoint.optString("~:graph-id").takeIf { it.isNotBlank() }
                    is JSONArray -> (1 until checkpoint.length() - 1 step 2)
                        .firstOrNull { checkpoint.optString(it) == "~:graph-id" }
                        ?.let { checkpoint.optString(it + 1).takeIf(String::isNotBlank) }
                    else -> null
                }
            }.getOrNull()
        }.distinct().sorted()
}
