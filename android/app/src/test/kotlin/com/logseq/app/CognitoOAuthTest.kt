package com.logseq.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CognitoOAuthTest {
    @Test
    fun `authorization URL uses PKCE and the configured callback`() {
        val url = CognitoOAuth.authorizationURL(
            domain = "login.example.com",
            clientID = "client id",
            redirectURI = "logseq://auth/callback",
            scopes = listOf("openid", "email"),
            state = "state-value",
            challenge = "challenge/value"
        )

        assertEquals(
            "https://login.example.com/oauth2/authorize?" +
                "client_id=client+id&code_challenge=challenge%2Fvalue&" +
                "code_challenge_method=S256&redirect_uri=" +
                "logseq%3A%2F%2Fauth%2Fcallback&response_type=code&" +
                "scope=openid+email&state=state-value",
            url
        )
    }

    @Test
    fun `form encoding is stable and escapes reserved characters`() {
        assertEquals(
            "client_id=a+b&code=a%2Bb%2Fc&grant_type=authorization_code",
            CognitoOAuth.formEncoded(
                mapOf(
                    "grant_type" to "authorization_code",
                    "code" to "a+b/c",
                    "client_id" to "a b"
                )
            )
        )
    }

    @Test
    fun `callback returns the authorization code after state validation`() {
        assertEquals(
            "code/value",
            CognitoOAuth.authorizationCode(
                "logseqchat://auth/callback?state=expected&code=code%2Fvalue",
                expectedState = "expected",
                redirectURI = "logseqchat://auth/callback"
            )
        )
    }

    @Test
    fun `callback rejects mismatched state`() {
        val error = assertThrows(IllegalStateException::class.java) {
            CognitoOAuth.authorizationCode(
                "logseq://auth/callback?state=unexpected&code=secret",
                expectedState = "expected",
                redirectURI = "logseq://auth/callback"
            )
        }

        assertEquals("The sign-in response could not be verified", error.message)
    }

    @Test
    fun `callback surfaces provider errors and missing codes`() {
        val providerError = assertThrows(IllegalStateException::class.java) {
            CognitoOAuth.authorizationCode(
                "logseq://auth/callback?state=expected&error=access_denied",
                expectedState = "expected",
                redirectURI = "logseq://auth/callback"
            )
        }
        val missingCode = assertThrows(IllegalStateException::class.java) {
            CognitoOAuth.authorizationCode(
                "logseq://auth/callback?state=expected",
                expectedState = "expected",
                redirectURI = "logseq://auth/callback"
            )
        }

        assertEquals("Sign-in failed: access_denied", providerError.message)
        assertEquals("Cognito did not return an authorization code", missingCode.message)
    }

    @Test
    fun `callback rejects unrelated deep links`() {
        val error = assertThrows(IllegalStateException::class.java) {
            CognitoOAuth.authorizationCode(
                "https://example.com/auth/callback?state=expected&code=secret",
                expectedState = "expected",
                redirectURI = "logseq://auth/callback"
            )
        }

        assertEquals("The sign-in callback URL is invalid", error.message)
    }
}
