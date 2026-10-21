package com.logseq.app

import android.os.Debug
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.LogseqNativeBridge
import com.logseq.app.runtime.LuiPatchFilter
import com.logseq.app.ui.extensions.logseqExtensionRegistry
import dev.lui.LuiBackend
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest

/** Opt-in CPU benchmark: replay real native viewport patches, without UI/gesture timing noise. */
@RunWith(AndroidJUnit4::class)
class AndroidPatchPerformanceTest {
    @Test fun replayNativeJournalViewportPatches() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("patchBenchmark") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val label = if (arguments.getString("benchmarkLabel") == "after") "after" else "before"
        val patches = mutableListOf<String>()
        val bridge = LogseqNativeBridge(onPatch = { patches.add(it) })
        val root = bridge.initialize(authenticationCode = 3)
        try {
            val rows = JSONArray()
            repeat(800) { index ->
                rows.put(JSONObject().put("depth", index % 4).put("hasChildren", index % 4 < 3)
                    .put("block", JSONObject().put("uuid", "patch-$index")
                        .put("title", "Row $index with **bold** and 中文 😀")
                        .put("pageId", "journal-${index / 8}")
                        .put("journalTitle", "Journal ${index / 8}").put("journalDay", 20261021)))
            }
            patches.add(bridge.applySnapshot(JSONObject().put("ok", true).put("result", JSONObject()
                .put("graphName", "Patch benchmark").put("selectedGraphId", "patch-benchmark")
                .put("isGraphUnlocked", true).put("outlinerRows", rows)).toString()))
            val window = patches.asSequence().flatMap { encoded ->
                val ops = JSONObject(encoded).getJSONArray("ops")
                (0 until ops.length()).asSequence().map(ops::getJSONObject)
            }.first { it.optString("property") == "data-attrs" &&
                it.optString("value").contains("data-virtual-count\u001f800") }.getLong("id")
            for (first in (0..768 step 32) + (768 downTo 0 step 32)) {
                bridge.visibleRange(window, first.toLong(), (first + 15).toLong())
            }
            val stream = File(context.filesDir, "patch-benchmark-stream.json")
            if (label == "before") {
                stream.writeText(JSONObject().put("root", root).put("patches", JSONArray(patches)).toString())
            }
            val fixture = JSONObject(stream.readText())
            val encoded = fixture.getJSONArray("patches")
            val replayPatches = (0 until encoded.length()).map(encoded::getString)
            val registry = logseqExtensionRegistry { it }
            fun replay(): Double {
                val backend = LuiBackend(extensions = registry)
                val filter = LuiPatchFilter(backend)
                val started = Debug.threadCpuTimeNanos()
                replayPatches.forEach(filter::applyJson)
                val elapsed = (Debug.threadCpuTimeNanos() - started) / 1e6
                assertTrue("Real native patch stream retains the application root", backend.node(fixture.getLong("root")) != null)
                return elapsed
            }
            repeat(6) { replay() }
            val samples = (0 until 12).map { replay() }
            val ordered = samples.sorted()
            val median = (ordered[(ordered.size - 1) / 2] + ordered[ordered.size / 2]) / 2
            val core = File(context.applicationInfo.nativeLibraryDir, "liblogseq_core.so")
            val checksum = MessageDigest.getInstance("SHA-256").digest(core.readBytes())
                .joinToString("") { "%02x".format(it) }
            val streamChecksum = MessageDigest.getInstance("SHA-256").digest(stream.readBytes())
                .joinToString("") { "%02x".format(it) }
            val report = JSONObject().put("patch_count", replayPatches.size)
                .put("patch_bytes", replayPatches.sumOf { it.toByteArray(Charsets.UTF_8).size })
                .put("cpu_ms", JSONArray(samples)).put("median_cpu_ms", median)
                .put("core_sha256", checksum).put("stream_sha256", streamChecksum).put("label", label)
            File(context.filesDir, "patch-benchmark-$label.json").writeText(report.toString(2))
            println("PATCH_BENCHMARK $report")
        } finally {
            bridge.close()
        }
    }
}
