package com.logseq.logseq

import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

// A JSON HTTPS adapter, with no authentication UI or challenge state.
internal class CognitoUserPool(
    region: String,
    private val clientId: String,
    private val endpoint: String = "https://cognito-idp.$region.amazonaws.com/",
) {
    suspend fun post(operation: String, body: JSONObject): JSONObject = withContext(Dispatchers.IO) {
        val payload = JSONObject(body.toString())
        if (operation != "AssociateSoftwareToken" && operation != "VerifySoftwareToken") {
            payload.put("ClientId", clientId)
        }
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/x-amz-json-1.1")
            connection.setRequestProperty("X-Amz-Target", "AWSCognitoIdentityProviderService.$operation")
            connection.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
            val succeeded = connection.responseCode in 200..299
            val encoded = (if (succeeded) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            val response = if (encoded.isEmpty() && succeeded) JSONObject() else JSONObject(encoded)
            if (!succeeded) {
                check(response.has("__type")) { "Authentication request failed: HTTP ${connection.responseCode}" }
                JSONObject().put("__type", response.getString("__type"))
            } else response
        } finally { connection.disconnect() }
    }
}
