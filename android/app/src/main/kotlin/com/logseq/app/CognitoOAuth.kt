package com.logseq.app

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

internal object CognitoOAuth {
    fun formEncoded(values: Map<String, String>): String = values.entries
        .sortedBy { it.key }
        .joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }

    fun authorizationURL(
        domain: String,
        clientID: String,
        redirectURI: String,
        scopes: List<String>,
        state: String,
        challenge: String
    ): String = "https://$domain/oauth2/authorize?" + formEncoded(
        mapOf(
            "response_type" to "code",
            "client_id" to clientID,
            "redirect_uri" to redirectURI,
            "scope" to scopes.joinToString(" "),
            "state" to state,
            "code_challenge" to challenge,
            "code_challenge_method" to "S256"
        )
    )

    fun authorizationCode(callbackURL: String, expectedState: String, redirectURI: String): String {
        val uri = URI(callbackURL)
        val redirect = URI(redirectURI)
        if (!uri.scheme.equals(redirect.scheme, ignoreCase = true) ||
            !uri.host.equals(redirect.host, ignoreCase = true) ||
            uri.path != redirect.path
        ) {
            throw IllegalStateException("The sign-in callback URL is invalid")
        }
        val values = queryValues(uri.rawQuery)
        if (values["state"] != expectedState) {
            throw IllegalStateException("The sign-in response could not be verified")
        }
        values["error"]?.takeIf { it.isNotBlank() }?.let { error ->
            throw IllegalStateException("Sign-in failed: $error")
        }
        return values["code"]?.takeIf { it.isNotBlank() }
            ?: throw IllegalStateException("Cognito did not return an authorization code")
    }

    private fun queryValues(rawQuery: String?): Map<String, String> = rawQuery
        .orEmpty()
        .split('&')
        .filter { it.isNotEmpty() }
        .associate { pair ->
            val separator = pair.indexOf('=')
            val key = if (separator < 0) pair else pair.substring(0, separator)
            val value = if (separator < 0) "" else pair.substring(separator + 1)
            decode(key) to decode(value)
        }

    private fun encode(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name())

    private fun decode(value: String): String =
        URLDecoder.decode(value, StandardCharsets.UTF_8.name())
}
