package com.logseq.app

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.browser.customtabs.CustomTabsIntent
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal class CognitoAuthProvider(
    context: Context,
    private val activity: Activity
) {
    private val applicationContext = context.applicationContext
    private val configuration = CognitoConfiguration.load(applicationContext)
    private val callbackLock = Any()
    private var pendingLogin: PendingLogin? = null

    fun hasStoredSession(): Boolean = hasStoredToken(
        preferences().getString(tokenPreference, null),
    )

    suspend fun accessToken(): String? {
        val current = loadTokens() ?: return null
        if (current.expiresAtMillis - System.currentTimeMillis() > refreshLeewayMillis) {
            return current.accessToken
        }
        return try {
            val refreshed = tokenRequest(
                mapOf(
                    "grant_type" to "refresh_token",
                    "client_id" to configuration.appClientID,
                    "refresh_token" to current.refreshToken
                ),
                previousRefreshToken = current.refreshToken
            )
            saveTokens(refreshed)
            refreshed.accessToken
        } catch (error: Throwable) {
            clearTokens()
            throw error
        }
    }

    suspend fun signIn(): String {
        val state = randomURLSafeString(24)
        val verifier = randomURLSafeString(64)
        val challenge = base64URL(
            MessageDigest.getInstance("SHA-256")
                .digest(verifier.toByteArray(StandardCharsets.UTF_8))
        )
        val code = suspendCancellableCoroutine { continuation ->
            synchronized(callbackLock) {
                if (pendingLogin != null) {
                    continuation.resumeWithException(
                        IllegalStateException("A sign-in request is already active")
                    )
                    return@suspendCancellableCoroutine
                }
                pendingLogin = PendingLogin(state, continuation)
            }
            continuation.invokeOnCancellation {
                synchronized(callbackLock) {
                    if (pendingLogin?.continuation === continuation) pendingLogin = null
                }
            }
            val authorizationURL = CognitoOAuth.authorizationURL(
                domain = configuration.oauthDomain,
                clientID = configuration.appClientID,
                redirectURI = configuration.redirectURI,
                scopes = configuration.scopes,
                state = state,
                challenge = challenge
            )
            runCatching {
                CustomTabsIntent.Builder().build().launchUrl(
                    activity,
                    Uri.parse(authorizationURL)
                )
            }.onFailure { error ->
                synchronized(callbackLock) { pendingLogin = null }
                if (continuation.isActive) continuation.resumeWithException(error)
            }
        }
        val tokens = tokenRequest(
            mapOf(
                "grant_type" to "authorization_code",
                "client_id" to configuration.appClientID,
                "code" to code,
                "redirect_uri" to configuration.redirectURI,
                "code_verifier" to verifier
            ),
            previousRefreshToken = null
        )
        require(tokens.refreshToken.isNotBlank()) {
            "Cognito did not return a refresh token"
        }
        saveTokens(tokens)
        return tokens.accessToken
    }

    suspend fun signOut() {
        val refreshToken = loadTokens()?.refreshToken
        clearTokens()
        if (!refreshToken.isNullOrBlank()) {
            runCatching {
                tokenPost(
                    endpoint("/oauth2/revoke"),
                    mapOf("client_id" to configuration.appClientID, "token" to refreshToken)
                )
            }
        }
    }

    fun handleCallback(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        val uri = Uri.parse(url)
        val redirect = Uri.parse(configuration.redirectURI)
        if (!uri.scheme.equals(redirect.scheme, ignoreCase = true) ||
            !uri.host.equals(redirect.host, ignoreCase = true) ||
            uri.path != redirect.path
        ) {
            return false
        }
        val pending = synchronized(callbackLock) {
            pendingLogin.also { pendingLogin = null }
        } ?: return true
        runCatching { CognitoOAuth.authorizationCode(url, pending.state, configuration.redirectURI) }
            .onSuccess { code ->
                if (pending.continuation.isActive) pending.continuation.resume(code)
            }
            .onFailure { error ->
                if (pending.continuation.isActive) {
                    pending.continuation.resumeWithException(error)
                }
            }
        return true
    }

    private suspend fun tokenRequest(
        values: Map<String, String>,
        previousRefreshToken: String?
    ): StoredTokens {
        val response = tokenPost(endpoint("/oauth2/token"), values)
        val accessToken = response.optString("access_token")
        require(accessToken.isNotBlank()) { "Cognito did not return an access token" }
        val refreshToken = response.optString("refresh_token").ifBlank {
            previousRefreshToken.orEmpty()
        }
        return StoredTokens(
            accessToken = accessToken,
            refreshToken = refreshToken,
            expiresAtMillis = System.currentTimeMillis() +
                response.optLong("expires_in", 3600) * 1000
        )
    }

    private suspend fun tokenPost(
        url: String,
        values: Map<String, String>
    ): JSONObject = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.doOutput = true
            connection.setRequestProperty(
                "Content-Type",
                "application/x-www-form-urlencoded"
            )
            connection.outputStream.use { output ->
                output.write(
                    CognitoOAuth.formEncoded(values).toByteArray(StandardCharsets.UTF_8)
                )
            }
            val succeeded = connection.responseCode in 200..299
            val body = (if (succeeded) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (!succeeded) {
                val reason = runCatching { JSONObject(body).optString("error") }
                    .getOrNull().orEmpty().ifBlank { "HTTP ${connection.responseCode}" }
                throw IllegalStateException("Cognito token request failed: $reason")
            }
            if (body.isBlank()) JSONObject() else JSONObject(body)
        } finally {
            connection.disconnect()
        }
    }

    private fun saveTokens(tokens: StoredTokens) {
        val encoded = JSONObject()
            .put("accessToken", tokens.accessToken)
            .put("refreshToken", tokens.refreshToken)
            .put("expiresAtMillis", tokens.expiresAtMillis)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
        val encrypted = JSONObject()
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put(
                "ciphertext",
                Base64.encodeToString(cipher.doFinal(encoded), Base64.NO_WRAP)
            )
            .toString()
        preferences().edit().putString(tokenPreference, encrypted).apply()
    }

    private fun loadTokens(): StoredTokens? {
        val encrypted = preferences().getString(tokenPreference, null) ?: return null
        return runCatching {
            val wrapper = JSONObject(encrypted)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                encryptionKey(),
                GCMParameterSpec(
                    128,
                    Base64.decode(wrapper.getString("iv"), Base64.NO_WRAP)
                )
            )
            val json = JSONObject(
                String(
                    cipher.doFinal(
                        Base64.decode(wrapper.getString("ciphertext"), Base64.NO_WRAP)
                    ),
                    StandardCharsets.UTF_8
                )
            )
            StoredTokens(
                accessToken = json.getString("accessToken"),
                refreshToken = json.getString("refreshToken"),
                expiresAtMillis = json.getLong("expiresAtMillis")
            )
        }.getOrElse {
            clearTokens()
            null
        }
    }

    private fun clearTokens() {
        preferences().edit().remove(tokenPreference).apply()
    }

    private fun preferences() = applicationContext.getSharedPreferences(
        "logseq-cognito-auth",
        Context.MODE_PRIVATE
    )

    private fun encryptionKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun endpoint(path: String) = "https://${configuration.oauthDomain}$path"

    private data class StoredTokens(
        val accessToken: String,
        val refreshToken: String,
        val expiresAtMillis: Long
    )

    private data class PendingLogin(
        val state: String,
        val continuation: CancellableContinuation<String>
    )

    private companion object {
        const val refreshLeewayMillis = 60_000L
        const val tokenPreference = "tokens"
        const val keyAlias = "com.logseq.app.cognito.tokens"
        val random = SecureRandom()

        fun randomURLSafeString(byteCount: Int): String {
            val bytes = ByteArray(byteCount)
            random.nextBytes(bytes)
            return base64URL(bytes)
        }

        fun base64URL(bytes: ByteArray): String = Base64.encodeToString(
            bytes,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )
    }
}

internal fun hasStoredToken(value: String?): Boolean = !value.isNullOrBlank()

private data class CognitoConfiguration(
    val region: String,
    val userPoolID: String,
    val appClientID: String,
    val oauthDomain: String,
    val redirectURI: String,
    val logoutURI: String,
    val scopes: List<String>
) {
    companion object {
        fun load(context: Context): CognitoConfiguration {
            val json = context.resources.openRawResource(R.raw.logseq_auth)
                .bufferedReader().use { JSONObject(it.readText()) }
            val encodedScopes = json.getJSONArray("scopes")
            return CognitoConfiguration(
                region = json.getString("region"),
                userPoolID = json.getString("userPoolId"),
                appClientID = json.getString("appClientId"),
                oauthDomain = json.getString("oauthDomain"),
                redirectURI = json.getString("redirectURI"),
                logoutURI = json.getString("logoutURI"),
                scopes = List(encodedScopes.length()) { index ->
                    encodedScopes.getString(index)
                }
            )
        }
    }
}
