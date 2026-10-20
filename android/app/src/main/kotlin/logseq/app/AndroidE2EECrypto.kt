package logseq.app

import androidx.annotation.Keep

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.KeyStore
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

// Native JNI calls these entry points by class and method name.
@Keep
object AndroidE2EECrypto {
    private const val preferenceName = "logseq.e2ee.secure-storage"
    private const val masterKeyAlias = "com.logseq.app.e2ee.storage"
    private const val passwordKey = "password"
    private const val graphKeyPrefix = "graph."
    private val random = SecureRandom()
    private lateinit var applicationContext: Context

    fun initialize(context: Context) {
        applicationContext = context.applicationContext
    }

    @JvmStatic
    fun call(requestJSON: String): String = try {
        handle(JSONObject(requestJSON)).toString()
    } catch (error: Throwable) {
        JSONObject()
            .put("ok", false)
            .put("error", error.message ?: error.javaClass.simpleName)
            .toString()
    }

    private fun handle(request: JSONObject): JSONObject = when (request.getString("operation")) {
        "generateRSAKeyPair" -> {
            val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(4096) }.generateKeyPair()
            JSONObject().put("ok", true).put("publicKey", pair.public.encoded.hex())
                .put("privateKey", pair.private.encoded.hex())
        }
        "encryptPrivateKey" -> {
            val salt = randomBytes(16)
            val key = pbkdf2(request.getString("password").toByteArray(Charsets.UTF_8), salt, 600000)
            val (iv, ciphertext) = aesEncrypt(key, request.hex("privateKey"))
            JSONObject().put("ok", true).put("salt", salt.hex()).put("iv", iv.hex())
                .put("ciphertext", ciphertext.hex())
        }
        "decryptPrivateKey" -> success(
            "value",
            decryptPrivateKey(
                password = request.getString("password"),
                iterations = request.getInt("iterations"),
                salt = request.hex("salt"),
                iv = request.hex("iv"),
                ciphertext = request.hex("ciphertext")
            ).hex()
        )
        "decryptGraphKey" -> success(
            "value",
            rsaCipher(Cipher.DECRYPT_MODE, request.hex("privateKey"), request.hex("ciphertext"), false).hex()
        )
        "encryptGraphKey" -> success(
            "value",
            rsaCipher(Cipher.ENCRYPT_MODE, request.hex("publicKey"), request.hex("plaintext"), true).hex()
        )
        "randomBytes" -> {
            val count = request.getInt("count")
            require(count > 0) { "invalid byte count" }
            success("value", randomBytes(count).hex())
        }
        "encryptAES" -> {
            val (iv, ciphertext) = aesEncrypt(request.hex("key"), request.hex("plaintext"))
            JSONObject().put("ok", true).put("iv", iv.hex()).put("ciphertext", ciphertext.hex())
        }
        "decryptAES" -> success(
            "value",
            aesDecrypt(request.hex("key"), request.hex("iv"), request.hex("ciphertext")).hex()
        )
        "saveGraphKey" -> {
            saveSecure(graphKeyPrefix + request.getString("graphID"), request.hex("key"))
            JSONObject().put("ok", true)
        }
        "loadGraphKey" -> nullableSuccess(loadSecure(graphKeyPrefix + request.getString("graphID")))
        "saveE2EEPassword" -> {
            saveSecure(passwordKey, request.hex("password"))
            JSONObject().put("ok", true)
        }
        "loadE2EEPassword" -> nullableSuccess(loadSecure(passwordKey))
        else -> error("unsupported operation")
    }

    private fun decryptPrivateKey(
        password: String,
        iterations: Int,
        salt: ByteArray,
        iv: ByteArray,
        ciphertext: ByteArray
    ): ByteArray {
        return aesDecrypt(pbkdf2(password.encodeToByteArray(), salt, iterations), iv, ciphertext)
    }

    private fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int): ByteArray {
        require(iterations > 0) { "invalid iterations" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(password, "HmacSHA256"))
        var previous = mac.doFinal(salt + byteArrayOf(0, 0, 0, 1))
        val derived = previous.copyOf()
        repeat(iterations - 1) {
            previous = mac.doFinal(previous)
            for (index in derived.indices) {
                derived[index] = (derived[index].toInt() xor previous[index].toInt()).toByte()
            }
        }
        return derived
    }

    private fun rsaCipher(
        mode: Int,
        encodedKey: ByteArray,
        input: ByteArray,
        publicKey: Boolean
    ): ByteArray {
        val factory = KeyFactory.getInstance("RSA")
        val key = if (publicKey) {
            factory.generatePublic(X509EncodedKeySpec(encodedKey))
        } else {
            factory.generatePrivate(PKCS8EncodedKeySpec(encodedKey))
        }
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        val parameters = OAEPParameterSpec(
            "SHA-256",
            "MGF1",
            MGF1ParameterSpec.SHA256,
            PSource.PSpecified.DEFAULT
        )
        cipher.init(mode, key, parameters)
        return cipher.doFinal(input)
    }

    private fun aesEncrypt(key: ByteArray, plaintext: ByteArray): Pair<ByteArray, ByteArray> {
        require(key.size == 32) { "invalid AES-GCM key" }
        val iv = randomBytes(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return iv to cipher.doFinal(plaintext)
    }

    private fun aesDecrypt(key: ByteArray, iv: ByteArray, ciphertext: ByteArray): ByteArray {
        require(key.size == 32 && iv.size == 12 && ciphertext.size >= 16) {
            "invalid AES-GCM input"
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun saveSecure(name: String, value: ByteArray) {
        check(::applicationContext.isInitialized) { "Android E2EE storage is unavailable" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, storageKey())
        val encoded = Base64.encodeToString(cipher.iv + cipher.doFinal(value), Base64.NO_WRAP)
        val stored = applicationContext.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
            .edit()
            .putString(name, encoded)
            .commit()
        check(stored) { "could not persist encrypted E2EE storage" }
    }

    private fun loadSecure(name: String): ByteArray? {
        check(::applicationContext.isInitialized) { "Android E2EE storage is unavailable" }
        val encoded = applicationContext.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
            .getString(name, null) ?: return null
        val payload = Base64.decode(encoded, Base64.NO_WRAP)
        require(payload.size >= 28) { "invalid encrypted E2EE storage" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            storageKey(),
            GCMParameterSpec(128, payload.copyOfRange(0, 12))
        )
        return cipher.doFinal(payload.copyOfRange(12, payload.size))
    }

    private fun storageKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(masterKeyAlias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                        masterKeyAlias,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build()
                )
            }
            .generateKey()
    }

    private fun nullableSuccess(value: ByteArray?): JSONObject = JSONObject()
        .put("ok", true)
        .put("value", value?.hex() ?: JSONObject.NULL)

    private fun success(name: String, value: String): JSONObject = JSONObject()
        .put("ok", true)
        .put(name, value)

    private fun JSONObject.hex(name: String): ByteArray = getString(name).hexBytes()

    private fun String.hexBytes(): ByteArray {
        require(length % 2 == 0) { "invalid hex" }
        return ByteArray(length / 2) { index ->
            substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)
}
