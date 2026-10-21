package com.logseq.app

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class AndroidGraphLocalStorageTest {
    @Test fun `named storage migrates legacy graphs and retains offline state`() {
        val root = java.nio.file.Files.createTempDirectory("graph-storage").toFile()
        try {
            val graphs = File(root, "graphs")
            val legacy = File(graphs, "graph-1").apply { mkdirs() }
            File(legacy, "graph.sqlite").writeText("database")
            File(legacy, "sync.checkpoint").writeText("checkpoint")
            File(legacy, "projection.sqlite").writeText("pending")
            val directory = AndroidGraphLocalStorage.prepare(graphs, "graph-1", "我的/Notes: Work")
            assertEquals("我的_Notes_ Work - graph-1", directory.name)
            assertFalse(legacy.exists())
            assertEquals("pending", File(directory, "projection.sqlite").readText())
            assertEquals(directory, AndroidGraphLocalStorage.directory(graphs, "graph-1"))
            assertEquals(listOf("graph-1"), AndroidGraphLocalStorage.localGraphIds(graphs))
            assertEquals(directory, AndroidGraphLocalStorage.prepare(graphs, "graph-1", "Renamed"))
            val other = AndroidGraphLocalStorage.prepare(graphs, "other", " .. ")
            assertEquals("Graph - other", other.name)
            val long = AndroidGraphLocalStorage.prepare(graphs, "long", "😀我的".repeat(100))
            assertTrue(long.name.toByteArray(Charsets.UTF_8).size <= 255)
            File(other, "graph.sqlite").writeText("incomplete")
            assertEquals(listOf("graph-1"), AndroidGraphLocalStorage.localGraphIds(graphs))
        } finally { root.deleteRecursively() }
    }
}
