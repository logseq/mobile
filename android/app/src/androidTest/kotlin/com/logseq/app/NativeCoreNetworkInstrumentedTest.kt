package com.logseq.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.net.InetAddress
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import logseq.app.AndroidHttpTransport
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeCoreNetworkInstrumentedTest {
    @Test
    fun graphDiscoveryUsesTheJvmTransportFromTheNativeCore() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        AndroidHttpTransport.initialize(context)
        val executor = Executors.newSingleThreadExecutor()
        val catalog = context.cacheDir.resolve("native-network-${UUID.randomUUID()}.sqlite")
        val tls = localTlsContext()
        val originalFactory = HttpsURLConnection.getDefaultSSLSocketFactory()
        HttpsURLConnection.setDefaultSSLSocketFactory(tls.socketFactory)
        tls.serverSocketFactory.createServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            server.soTimeout = 10_000
            val received = executor.submit<List<String>> {
                server.accept().use { socket ->
                    socket.soTimeout = 10_000
                    val reader = socket.getInputStream().bufferedReader()
                    val headers = mutableListOf<String>()
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        headers.add(line)
                    }
                    val body = """{"graphs":[{"graph-id":"network-test","graph-name":"Network test","graph-e2ee?":false,"graph-ready-for-use?":true}]}"""
                    socket.getOutputStream().write(
                        ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                            "Content-Length: ${body.toByteArray().size}\r\nConnection: close\r\n\r\n" + body).toByteArray()
                    )
                    headers
                }
            }
            try {
                call("open", JSONObject().put("path", catalog.absolutePath))
                call("dispatch", JSONObject().put("action", "configure").put("payload",
                    JSONObject().put("baseUrl", "https://127.0.0.1:${server.localPort}")
                        .put("graphId", "").put("token", "native-network-test").toString()))
                val result = call("dispatch", JSONObject().put("action", "refreshGraphCatalog").put("payload", ""))
                assertEquals(result.toString(), "network-test", result.getJSONArray("graphs").optJSONObject(0)?.optString("id"))
                val headers = received.get(10, TimeUnit.SECONDS)
                assertEquals("GET /graphs HTTP/1.1", headers.first())
                assertTrue(headers.any { it.equals("Authorization: Bearer native-network-test", ignoreCase = true) })
            } finally {
                executor.shutdownNow()
                HttpsURLConnection.setDefaultSSLSocketFactory(originalFactory)
                catalog.delete()
            }
        }
    }

    private fun localTlsContext(): SSLContext {
        val password = "android-test".toCharArray()
        val store = KeyStore.getInstance("PKCS12")
        InstrumentationRegistry.getInstrumentation().context.assets.open("native-network-test.p12").use {
            store.load(it, password)
        }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password) }
        val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
        return SSLContext.getInstance("TLS").apply { init(keys.keyManagers, trust.trustManagers, null) }
    }

    private fun call(method: String, params: JSONObject): JSONObject {
        val request = JSONObject().put("apiVersion", 1).put("method", method).put("params", params)
        val response = JSONObject(requireNotNull(NativeCore.logseqCall(request.toString().toByteArray())).toString(Charsets.UTF_8))
        assertTrue(response.toString(), response.getBoolean("ok"))
        return response.getJSONObject("result")
    }
}
