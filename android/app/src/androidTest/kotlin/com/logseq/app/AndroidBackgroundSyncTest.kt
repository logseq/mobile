package com.logseq.app

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.Context
import android.content.ContextWrapper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import com.logseq.app.runtime.AndroidBackgroundSync
import com.logseq.app.runtime.BackgroundSyncResult
import com.logseq.app.runtime.NativeCoreSession
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class AndroidBackgroundSyncTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val root = File(base.cacheDir, "background-${UUID.randomUUID()}").apply { mkdirs() }
    private val isolated = object : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = root
        override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences("${root.name}-$name", mode)
    }

    @After fun cleanup() {
        root.deleteRecursively()
        for (name in listOf("logseq", "logseq-cognito-auth", "logseq.e2ee.secure-storage")) {
            base.deleteSharedPreferences("${root.name}-$name")
        }
    }

    @Suppress("DEPRECATION")
    @Test fun schedulingIsUniquePersistentAndRequiresNetwork() {
        val scheduler = base.getSystemService(JobScheduler::class.java)
        scheduler.cancel(AndroidBackgroundSync.jobId)
        AndroidBackgroundSync.schedule(base)
        AndroidBackgroundSync.schedule(base)
        val jobs = scheduler.allPendingJobs.filter { it.id == AndroidBackgroundSync.jobId }
        assertEquals(1, jobs.size)
        val job = jobs.single()
        assertTrue(job.isPersisted)
        assertTrue(job.isPeriodic)
        assertTrue(job.intervalMillis >= 15 * 60 * 1000L)
        assertEquals(JobInfo.NETWORK_TYPE_ANY, job.networkType)
        assertEquals("com.logseq.app.AndroidSyncJobService", job.service.className)
    }

    @Test fun noStoredSessionOrSelectedGraphDoesNotStartNativeSync(): Unit = runBlocking {
        assertEquals(BackgroundSyncResult.Skipped, AndroidBackgroundSync.run(isolated))
        isolated.getSharedPreferences("logseq", 0).edit().putString("logseq.selectedGraphId", "background-qa").commit()
        assertEquals(BackgroundSyncResult.Skipped, AndroidBackgroundSync.run(isolated))
    }

    @Test fun authenticatedNativeSyncPersistsTheReceivedServerCursor(): Unit = runBlocking {
        SocketServer().use { server ->
            prepare(server.port)
            val result = AndroidBackgroundSync.run(isolated)
            val state = JSONObject(String(requireNotNull(NativeCore.logseqCall("""{"apiVersion":1,"method":"snapshot","params":{}}""".toByteArray()))))
            assertEquals(state.optJSONObject("result")?.optString("pendingSyncError"), BackgroundSyncResult.Success, result)
            val request = withContext(Dispatchers.IO) { server.received.get(10, TimeUnit.SECONDS) }
            assertTrue(request.contains("Authorization: Bearer background-qa-token", ignoreCase = true))
            assertTrue(request.contains("background-qa"))
            assertTrue(request.contains("pull"))
            val checkpoint = JSONArray(File(root, "graphs/Graph-background-qa/sync.checkpoint").readText())
            val index = (1 until checkpoint.length()).first { checkpoint.optString(it) == "~:applied-server-t" }
            assertEquals(1, checkpoint.getInt(index + 1))
        }
    }

    @Test fun failedNetworkRequestsAreRetriedAndCancellationReleasesTheCore(): Unit = runBlocking {
        SocketServer(reject = true).use { server ->
            prepare(server.port)
            assertEquals(BackgroundSyncResult.Retry, AndroidBackgroundSync.run(isolated))
            assertFalse(NativeCoreSession.gate.isLocked)
        }
        SocketServer(stall = true).use { server ->
            prepare(server.port)
            val work = async { AndroidBackgroundSync.run(isolated) }
            withContext(Dispatchers.IO) { server.received.get(10, TimeUnit.SECONDS) }
            work.cancelAndJoin()
            assertTrue(work.isCancelled)
            assertFalse(NativeCoreSession.gate.isLocked)
        }
    }

    @Suppress("DEPRECATION")
    @Test fun failedTokenRefreshKeepsStoredCredentialsForTheNextAttempt(): Unit = runBlocking {
        prepare(18790, expiresAtMillis = 0)
        val json = base.resources.openRawResource(R.raw.logseq_auth).bufferedReader().use { JSONObject(it.readText()) }
            .put("oauthDomain", "127.0.0.1:1").toString()
        val resources = object : android.content.res.Resources(base.assets, base.resources.displayMetrics, base.resources.configuration) {
            override fun openRawResource(id: Int): java.io.InputStream = if (id == R.raw.logseq_auth)
                java.io.ByteArrayInputStream(json.toByteArray()) else base.resources.openRawResource(id)
        }
        val context = object : ContextWrapper(isolated) {
            override fun getApplicationContext(): Context = this
            override fun getResources() = resources
        }
        val auth = CognitoAuthProvider(context)
        assertTrue(auth.hasStoredSession())
        try { auth.apiToken(); fail("The offline refresh should fail") } catch (_: java.io.IOException) { }
        assertTrue("A temporary network error must retain the encrypted refresh token", auth.hasStoredSession())
    }

    @Test fun anActiveCoreLeasePreventsASecondSessionFromReplacingTheEditor(): Unit = runBlocking {
        prepare(18790)
        val owner = Any()
        NativeCoreSession.gate.lock(owner)
        try { assertEquals(BackgroundSyncResult.Retry, AndroidBackgroundSync.run(isolated)) }
        finally { NativeCoreSession.gate.unlock(owner) }
    }

    private fun prepare(port: Int, expiresAtMillis: Long = System.currentTimeMillis() + 86_400_000) {
        val source = InstrumentationRegistry.getArguments().getString("backgroundGraphFixture")
        assumeTrue("Supply a prepared dedicated QA graph for native integration checks", source != null)
        val directory = File(root, "graphs/Graph-background-qa").apply { mkdirs() }
        File(requireNotNull(source)).copyTo(File(directory, "graph.sqlite"), overwrite = true)
        File(directory, "sync.checkpoint").writeText("""["^ ","~:format-version",1,"~:graph-id","background-qa","~:schema-version","65.34","~:applied-server-t",0]""")
        isolated.getSharedPreferences("logseq", 0).edit().putString("logseq.selectedGraphId", "background-qa")
            .putString("logseq.baseURL", "http://127.0.0.1:$port").commit()
        val alias = "com.logseq.app.cognito.tokens"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        val payload = JSONObject().put("idToken", "background-qa-token").put("refreshToken", "background-qa-refresh")
            .put("expiresAtMillis", expiresAtMillis).toString().toByteArray()
        val encrypted = JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(cipher.doFinal(payload), Base64.NO_WRAP)).toString()
        isolated.getSharedPreferences("logseq-cognito-auth", 0).edit().putString("tokens", encrypted).commit()
    }

    private class SocketServer(private val reject: Boolean = false, private val stall: Boolean = false) : AutoCloseable {
        private val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val port get() = server.localPort
        val received = CompletableFuture<String>()
        private var connection: java.net.Socket? = null
        private val thread = Thread {
            try {
                server.accept().use { socket ->
                    connection = socket
                    socket.soTimeout = 10_000
                    val input = socket.getInputStream()
                    val header = StringBuilder()
                    while (!header.endsWith("\r\n\r\n")) { val n = input.read(); check(n >= 0); header.append(n.toChar()) }
                    android.util.Log.i("BackgroundSyncTest", "Received " + header.lineSequence().first())
                    val output = socket.getOutputStream()
                    if (reject) {
                        received.complete(header.toString())
                        output.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                    } else {
                        val key = header.lines().single { it.startsWith("Sec-WebSocket-Key:", ignoreCase = true) }.substringAfter(':').trim()
                        val accept = Base64.encodeToString(MessageDigest.getInstance("SHA-1").digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()), Base64.NO_WRAP)
                        output.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n").toByteArray()); output.flush()
                        input.read()
                        val size = input.read() and 127
                        val length = if (size == 126) (input.read() shl 8) or input.read() else size
                        val mask = ByteArray(4).apply { for (i in indices) this[i] = input.read().toByte() }
                        val payload = ByteArray(length).apply { for (i in indices) this[i] = (input.read() xor mask[i % 4].toInt()).toByte() }
                        received.complete(header.toString() + String(payload))
                        if (!stall) {
                            val frame = """{"type":"pull/ok","t":1,"t-before":0,"txs":[]}""".toByteArray()
                            output.write(byteArrayOf(0x81.toByte(), frame.size.toByte()) + frame); output.flush()
                        }
                        while (input.read() >= 0) { }
                    }
                }
            } catch (error: Throwable) {
                android.util.Log.i("BackgroundSyncTest", "Server ended: $error")
                received.completeExceptionally(error)
            }
        }.apply { isDaemon = true; start() }
        override fun close() { connection?.close(); server.close(); thread.join(1_000) }
    }
}
