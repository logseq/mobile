package com.logseq.app.runtime

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CoreBootstrapTest {
    @Test fun cachedEncryptedGraphOpensOnlyWhenTheCoreHasUnlockedIt(): Unit = runBlocking {
        for (unlocked in listOf(false, true)) {
            val directory = Files.createTempDirectory("encrypted-bootstrap").toFile()
            val requests = mutableListOf<JSONObject>()
            try {
                val result = CoreBootstrap({ raw ->
                    val request = JSONObject(raw)
                    requests.add(request)
                    val response = if (request.getString("method") == "open") {
                        JSONObject("""{"graphs":[{"id":"encrypted","name":"Encrypted","isEncrypted":true}]}""")
                    } else JSONObject().put("isGraphUnlocked", unlocked)
                    JSONObject().put("ok", true).put("result", response).toString()
                }).restore(CoreStartupState("${directory.path}/catalog.sqlite", "${directory.path}/graphs",
                    "http://127.0.0.1", "encrypted", listOf("encrypted"), "test-token"))
                val opens = requests.filter { it.getJSONObject("params").optString("action") == "openGraph" }
                assertEquals(if (unlocked) 1 else 0, opens.size)
                assertEquals(unlocked, result.graphResponse != null)
                if (unlocked) assertTrue(JSONObject(opens.single().getJSONObject("params").getString("payload")).getBoolean("isEncrypted"))
            } finally { directory.deleteRecursively() }
        }
    }
}
