package com.logseq.logseq

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

internal class CognitoAuthProvider(context: Context, transport: CognitoUserPool? = null) {
    private val applicationContext = context.applicationContext
    private val configuration = CognitoConfiguration.load(applicationContext)
    private val transport = transport ?: CognitoUserPool(configuration.region, configuration.appClientID)

    fun hasStoredSession(): Boolean = hasStoredToken(preferences().getString(tokenPreference, null))

    suspend fun apiToken(): String? = sessionTokens()?.idToken

    private suspend fun sessionTokens(refresh: Boolean = false, needsAccess: Boolean = false): StoredTokens? {
        val current = loadTokens() ?: return null
        if (current.refreshToken.isBlank()) { clearTokens(); return null }
        if (!refresh && (!needsAccess || current.accessToken != null) && !current.idToken.isNullOrBlank() &&
            current.expiresAtMillis - System.currentTimeMillis() > refreshLeewayMillis) return current
        val response = try {
            transport.post("GetTokensFromRefreshToken", JSONObject().put("RefreshToken", current.refreshToken))
        } catch (error: IOException) {
            throw CognitoSessionUnavailableException(error)
        }
        val error = response.optString("__type").substringAfterLast('#')
        if (error in setOf("NotAuthorizedException", "RefreshTokenReuseException")) {
            clearTokens()
            return null
        }
        if (error in setOf("TooManyRequestsException", "InternalErrorException", "ServiceUnavailableException")) {
            throw CognitoSessionUnavailableException()
        }
        check(error.isEmpty()) { "Authentication request failed: $error" }
        val refreshed = tokens(response, current.refreshToken)
        saveTokens(refreshed)
        return refreshed
    }

    suspend fun readProfile(): AccountProfile {
        val access = checkNotNull(sessionTokens(needsAccess = true)?.accessToken)
        val response = transport.post("GetUser", JSONObject().put("AccessToken", access))
        check(!response.has("__type"))
        val attributes = response.getJSONArray("UserAttributes")
        fun value(key: String): String? = (0 until attributes.length()).firstNotNullOfOrNull { index ->
            attributes.getJSONObject(index).let { if (it.optString("Name") == key) it.optString("Value") else null }
        }
        return AccountProfile(value("name").orEmpty(), value("picture"))
    }

    suspend fun updateProfile(fullName: String, photo: ByteArray?) {
        val tokens = checkNotNull(sessionTokens(needsAccess = true))
        val attributes = JSONArray().put(JSONObject().put("Name", "name").put("Value", fullName))
        if (photo != null) {
            val url = uploadProfilePhoto(photo, checkNotNull(tokens.idToken))
            attributes.put(JSONObject().put("Name", "picture").put("Value", url))
        }
        val response = transport.post("UpdateUserAttributes", JSONObject().put("AccessToken", tokens.accessToken)
            .put("UserAttributes", attributes))
        check(!response.has("__type"))
        sessionTokens(refresh = true)
    }

    private suspend fun uploadProfilePhoto(photo: ByteArray, idToken: String): String = withContext(Dispatchers.IO) {
        require(photo.isNotEmpty() && photo.size <= 128 * 1024)
        val authorize = Request.Builder().url("https://api.logseq.com/logseq/get_presigned_user_avatar_put_url")
            .header("Authorization", "Bearer $idToken").post(byteArrayOf().toRequestBody()).build()
        val signed = profileClient.newCall(authorize).execute().use { response ->
            check(response.code == 200)
            checkNotNull(JSONObject(response.body!!.string()).getString("presigned-url").toHttpUrlOrNull())
        }
        check(signed.isHttps && signed.host == "logseq-user-public-metadata-bucket-prod.s3.amazonaws.com")
        val upload = Request.Builder().url(signed).header("Cache-Control", "public, max-age=0")
            .put(photo.toRequestBody("image/jpeg".toMediaType())).build()
        profileClient.newCall(upload).execute().use { check(it.code == 200) }
        signed.newBuilder().query(null).build().toString()
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
        return StoredTokens(idToken, result.optString("AccessToken").takeIf { it.isNotBlank() },
            refreshToken, System.currentTimeMillis() + expiresIn * 1000)
    }

    private fun saveTokens(tokens: StoredTokens) {
        val encoded = JSONObject()
            .put("idToken", tokens.idToken)
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
                idToken = json.optString("idToken").takeIf { it.isNotBlank() },
                accessToken = json.optString("accessToken").takeIf { it.isNotBlank() },
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

    private data class StoredTokens(val idToken: String?, val accessToken: String?, val refreshToken: String, val expiresAtMillis: Long)

    private companion object {
        val profileClient = OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).followRedirects(false).build()
        const val refreshLeewayMillis = 60_000L
        const val tokenPreference = "tokens"
        const val keyAlias = "com.logseq.logseq.cognito.tokens"
        val interactiveOperations = setOf("InitiateAuth", "RespondToAuthChallenge", "SignUp", "ConfirmSignUp",
            "ResendConfirmationCode", "ForgotPassword", "ConfirmForgotPassword", "AssociateSoftwareToken", "VerifySoftwareToken")
    }
}

internal data class AccountProfile(val fullName: String, val photo: String?)

internal fun hasStoredToken(value: String?): Boolean = !value.isNullOrBlank()

internal class CognitoSessionUnavailableException(cause: IOException? = null) :
    IOException("Authentication is temporarily unavailable", cause)

private data class CognitoConfiguration(val region: String, val appClientID: String) {
    companion object {
        fun load(context: Context): CognitoConfiguration {
            val json = context.resources.openRawResource(R.raw.logseq_auth)
                .bufferedReader().use { JSONObject(it.readText()) }
            return CognitoConfiguration(json.getString("region"), json.getString("appClientId"))
        }
    }
}
