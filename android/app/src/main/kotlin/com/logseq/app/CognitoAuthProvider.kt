package com.logseq.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

internal class CognitoAuthProvider(context: Context, transport: CognitoUserPool? = null) {
    private val applicationContext = context.applicationContext
    private val configuration = CognitoConfiguration.load(applicationContext)
    private val transport = transport ?: CognitoUserPool(configuration.region, configuration.appClientID)

    fun hasStoredSession(): Boolean = hasStoredToken(preferences().getString(tokenPreference, null))

    suspend fun apiToken(): String? {
        val current = loadTokens() ?: return null
        if (current.refreshToken.isBlank()) { clearTokens(); return null }
        if (!current.idToken.isNullOrBlank() && current.expiresAtMillis - System.currentTimeMillis() > refreshLeewayMillis) {
            return current.idToken
        }
        val response = transport.post("GetTokensFromRefreshToken", JSONObject().put("RefreshToken", current.refreshToken))
        val error = response.optString("__type").substringAfterLast('#')
        if (error in setOf("NotAuthorizedException", "RefreshTokenReuseException")) {
            clearTokens()
            return null
        }
        check(error.isEmpty()) { "Authentication request failed: $error" }
        val refreshed = tokens(response, current.refreshToken)
        saveTokens(refreshed)
        return refreshed.idToken
    }

    // The shared OCaml form owns all challenge and recovery decisions.
    suspend fun authenticate(encoded: String): String {
        val request = JSONObject(encoded)
        val operation = request.getString("operation")
        require(operation in interactiveOperations) { "Unsupported authentication operation" }
        val response = transport.post(operation, request.getJSONObject("body"))
        if (response.has("AuthenticationResult")) {
            require(operation == "InitiateAuth" || operation == "RespondToAuthChallenge")
            saveTokens(tokens(response, null))
            return "{\"signedIn\":true}"
        }
        val sanitized = JSONObject()
        for (key in listOf("__type", "ChallengeName", "ChallengeParameters", "Session", "UserConfirmed",
            "CodeDeliveryDetails", "SecretCode", "Status")) {
            if (response.has(key)) sanitized.put(key, response.get(key))
        }
        return sanitized.toString()
    }

    suspend fun signOut() {
        val refreshToken = loadTokens()?.refreshToken
        clearTokens()
        if (!refreshToken.isNullOrBlank()) {
            try { transport.post("RevokeToken", JSONObject().put("Token", refreshToken)) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { /* Local sign-out succeeds even while offline. */ }
        }
    }

    private fun tokens(response: JSONObject, previousRefreshToken: String?): StoredTokens {
        val result = response.getJSONObject("AuthenticationResult")
        val idToken = result.optString("IdToken")
        require(idToken.isNotBlank()) { "Cognito did not return an ID token" }
        val refreshToken = result.optString("RefreshToken").ifBlank { previousRefreshToken.orEmpty() }
        require(refreshToken.isNotBlank()) { "Cognito did not return a refresh token" }
        val expiresIn = result.optLong("ExpiresIn", 0)
        require(expiresIn > 0) { "Cognito returned an invalid token expiry" }
        return StoredTokens(idToken, refreshToken, System.currentTimeMillis() + expiresIn * 1000)
    }

    private fun saveTokens(tokens: StoredTokens) {
        val encoded = JSONObject()
            .put("idToken", tokens.idToken)
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
                idToken = json.optString("idToken").takeIf { it.isNotBlank() },
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

    private data class StoredTokens(val idToken: String?, val refreshToken: String, val expiresAtMillis: Long)

    private companion object {
        const val refreshLeewayMillis = 60_000L
        const val tokenPreference = "tokens"
        const val keyAlias = "com.logseq.app.cognito.tokens"
        val interactiveOperations = setOf("InitiateAuth", "RespondToAuthChallenge", "SignUp", "ConfirmSignUp",
            "ResendConfirmationCode", "ForgotPassword", "ConfirmForgotPassword", "AssociateSoftwareToken", "VerifySoftwareToken")
    }
}

internal fun hasStoredToken(value: String?): Boolean = !value.isNullOrBlank()

private data class CognitoConfiguration(val region: String, val appClientID: String) {
    companion object {
        fun load(context: Context): CognitoConfiguration {
            val json = context.resources.openRawResource(R.raw.logseq_auth)
                .bufferedReader().use { JSONObject(it.readText()) }
            return CognitoConfiguration(json.getString("region"), json.getString("appClientId"))
        }
    }
}
