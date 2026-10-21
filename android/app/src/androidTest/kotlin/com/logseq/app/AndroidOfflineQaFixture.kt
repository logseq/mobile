package com.logseq.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Explicit offline QA setup, excluded from ordinary test runs. Never a login test. */
class AndroidOfflineQaFixture {
    @Test fun installOfflineSessionForPreparedFixture() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("installOfflineFixture") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("logseq", Context.MODE_PRIVATE)
        assertTrue("Only the dedicated QA graph may receive an offline session",
            preferences.getString("logseq.selectedGraphId", "") == "uiregression")
        assertTrue(File(context.filesDir, "graphs/UI_Regression-uiregression/sync.checkpoint").isFile)
        assertTrue(preferences.edit().putString("logseq.baseURL", "http://127.0.0.1:8787").commit())
        val alias = "com.logseq.app.cognito.tokens"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        val payload = JSONObject().put("idToken", "offline-qa-token").put("refreshToken", "offline-qa-refresh")
            .put("expiresAtMillis", System.currentTimeMillis() + 86_400_000).toString().toByteArray()
        val encrypted = JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(cipher.doFinal(payload), Base64.NO_WRAP)).toString()
        assertTrue(context.getSharedPreferences("logseq-cognito-auth", Context.MODE_PRIVATE)
            .edit().putString("tokens", encrypted).commit())
    }
}
