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
            File(legacy, "sync.checkpoint").writeText("""["^ ","~:format-version",1,"~:graph-id","graph-1","~:schema-version","1","~:applied-server-t",7]""")
            File(legacy, "projection.sqlite").writeText("pending")
            val directory = AndroidGraphLocalStorage.prepare(graphs, "graph-1", "我的/Notes: Work")
            assertEquals("我的_Notes_Work-graph-1", directory.name)
            assertFalse(legacy.exists())
            assertEquals("pending", File(directory, "projection.sqlite").readText())
            assertEquals(directory, AndroidGraphLocalStorage.directory(graphs, "graph-1"))
            assertEquals(listOf("graph-1"), AndroidGraphLocalStorage.localGraphIds(graphs))
            assertEquals(directory, AndroidGraphLocalStorage.prepare(graphs, "graph-1", "Renamed"))
            val other = AndroidGraphLocalStorage.prepare(graphs, "other", " .. ")
            assertEquals("Graph-other", other.name)
            val long = AndroidGraphLocalStorage.prepare(graphs, "long", "😀我的".repeat(100))
            assertTrue(long.name.toByteArray(Charsets.UTF_8).size <= 255)
            File(other, "graph.sqlite").writeText("incomplete")
            assertEquals(listOf("graph-1"), AndroidGraphLocalStorage.localGraphIds(graphs))
        } finally { root.deleteRecursively() }
    }
    @Test fun `spaced directories migrate with assets and readable unicode names`() {
        val root = java.nio.file.Files.createTempDirectory("graph-spaces").toFile()
        try {
            val graphs = File(root, "graphs")
            val old = File(graphs, "我的 Notes 😀 - graph-1").apply { mkdirs() }
            File(old, "Assets").mkdirs()
            File(old, "Assets/photo.png").writeText("photo")
            File(old, "graph.sqlite").writeText("database")
            File(old, "sync.checkpoint").writeText("""["^ ","~:format-version",1,"~:graph-id","graph-1","~:schema-version","1","~:applied-server-t",7]""")
            assertEquals(listOf("graph-1"), AndroidGraphLocalStorage.localGraphIds(graphs))
            val directory = AndroidGraphLocalStorage.prepare(graphs, "graph-1", "我的\tNotes\u00A0😀")
            assertEquals("我的_Notes_😀-graph-1", directory.name)
            assertEquals("photo", File(directory, "Assets/photo.png").readText())
            assertFalse(old.exists())
            assertEquals(listOf("graph-1"), AndroidGraphLocalStorage.localGraphIds(graphs))
        } finally { root.deleteRecursively() }
    }
}
