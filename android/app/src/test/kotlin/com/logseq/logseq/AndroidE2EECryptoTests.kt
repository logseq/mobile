package com.logseq.logseq

import java.security.KeyPairGenerator
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidE2EECryptoTests {
    @Test
    fun aesGCMRoundTripMatchesTheNativeBridgeContract() {
        val key = ByteArray(32) { it.toByte() }.hex()
        val plaintext = "Logseq encrypted graph".encodeToByteArray().hex()
        val encrypted = response(
            AndroidE2EECrypto.call(
                """{"operation":"encryptAES","key":"$key","plaintext":"$plaintext"}"""
            )
        )

        assertTrue(encrypted.getBoolean("ok"))
        assertEquals(24, encrypted.getString("iv").length)
        assertNotEquals(plaintext, encrypted.getString("ciphertext"))

        val decrypted = response(
            AndroidE2EECrypto.call(
                """{"operation":"decryptAES","key":"$key","iv":"${encrypted.getString("iv")}","ciphertext":"${encrypted.getString("ciphertext")}"}"""
            )
        )
        assertEquals(plaintext, decrypted.getString("value"))
    }

    @Test
    fun rsaOAEPGraphKeyRoundTripAcceptsLogseqKeyEncodings() {
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val graphKey = ByteArray(32) { (it * 3).toByte() }.hex()
        val encrypted = response(
            AndroidE2EECrypto.call(
                """{"operation":"encryptGraphKey","publicKey":"${pair.public.encoded.hex()}","plaintext":"$graphKey"}"""
            )
        )
        assertTrue(encrypted.getBoolean("ok"))

        val decrypted = response(
            AndroidE2EECrypto.call(
                """{"operation":"decryptGraphKey","privateKey":"${pair.private.encoded.hex()}","ciphertext":"${encrypted.getString("value")}"}"""
            )
        )
        assertEquals(graphKey, decrypted.getString("value"))
    }

    @Test
    fun secureRandomReturnsTheRequestedNumberOfBytes() {
        val first = response(AndroidE2EECrypto.call("""{"operation":"randomBytes","count":32}"""))
        val second = response(AndroidE2EECrypto.call("""{"operation":"randomBytes","count":32}"""))
        assertEquals(64, first.getString("value").length)
        assertNotEquals(first.getString("value"), second.getString("value"))
    }

    @Test
    fun privateKeyDecryptionUsesPBKDF2HMACSHA256() {
        val derivedKey = "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
            .hexBytes()
        val iv = ByteArray(12) { it.toByte() }
        val plaintext = "PKCS8 private key".encodeToByteArray()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(derivedKey, "AES"),
            GCMParameterSpec(128, iv)
        )
        val response = response(
            AndroidE2EECrypto.call(
                """{"operation":"decryptPrivateKey","password":"password","iterations":2,"salt":"${"salt".encodeToByteArray().hex()}","iv":"${iv.hex()}","ciphertext":"${cipher.doFinal(plaintext).hex()}"}"""
            )
        )
        assertEquals(plaintext.hex(), response.getString("value"))
    }

    private fun response(value: String): JSONObject = JSONObject(value)

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun String.hexBytes(): ByteArray = ByteArray(length / 2) { index ->
        substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}
