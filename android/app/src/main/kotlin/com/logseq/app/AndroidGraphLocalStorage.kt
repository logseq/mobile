package com.logseq.app

import java.io.File
import java.net.URLEncoder

internal object AndroidGraphLocalStorage {
    private fun encodedId(id: String) = URLEncoder.encode(id, "UTF-8")
        .replace("+", "%20").replace(".", "%2E").replace("*", "%2A")

    private fun folderName(name: String): String {
        val prefix = StringBuilder()
        var byteCount = 0
        val scalars = name.codePoints().iterator()
        while (scalars.hasNext()) {
            val scalar = scalars.nextInt()
            val safe = if (Character.isISOControl(scalar) || scalar in listOf(47, 92, 58)) "_"
                else String(Character.toChars(scalar))
            val size = safe.toByteArray(Charsets.UTF_8).size
            if (byteCount + size > 120) break
            prefix.append(safe)
            byteCount += size
        }
        return prefix.toString().trim { it.isWhitespace() || it == '.' }.ifEmpty { "Graph" }
    }

    fun directory(graphs: File, graphId: String, graphName: String = "Graph"): File {
        val id = encodedId(graphId)
        graphs.listFiles().orEmpty().filter { it.isDirectory && it.name.endsWith(" - $id") }
            .sortedBy { it.name }.firstOrNull()?.let { return it }
        val legacy = File(graphs, id)
        if (legacy.isDirectory) return legacy
        return File(graphs, "${folderName(graphName)} - $id")
    }

    // Resolve before opening database handles; existing named folders remain stable after graph renames.
    fun prepare(graphs: File, graphId: String, graphName: String): File {
        val existing = directory(graphs, graphId, graphName)
        if (existing.name.endsWith(" - ${encodedId(graphId)}")) {
            check(existing.isDirectory || existing.mkdirs()) { "Could not create graph directory: $existing" }
            return existing
        }
        val destination = File(graphs, "${folderName(graphName)} - ${encodedId(graphId)}")
        check(existing.renameTo(destination)) { "Could not migrate graph directory: $existing" }
        return destination
    }

    fun localGraphIds(graphs: File): List<String> = graphs.listFiles().orEmpty()
        .filter { it.isDirectory && File(it, "graph.sqlite").isFile && File(it, "sync.checkpoint").isFile }
        .map { java.net.URLDecoder.decode(it.name.substringAfterLast(" - "), "UTF-8") }.sorted()
}
