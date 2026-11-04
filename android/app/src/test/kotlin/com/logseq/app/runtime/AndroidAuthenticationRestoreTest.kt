package com.logseq.app.runtime

import com.logseq.app.CognitoSessionUnavailableException
import java.net.UnknownHostException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class AndroidAuthenticationRestoreTest {
    @Test fun `local session survives unavailable refresh without a remote token`(): Unit = runBlocking {
        data class Case(
            val name: String,
            val hasStoredSession: Boolean = true,
            val token: String? = null,
            val error: Throwable? = null,
            val expected: AndroidRestoredAuthentication? = null,
        )
        val cancelled = CancellationException("cancelled")
        val invalidState = IllegalStateException("invalid state")
        for (case in listOf(
            Case("fresh token", token = "fresh-token",
                expected = AndroidRestoredAuthentication("fresh-token", true)),
            Case("no stored session", hasStoredSession = false,
                error = AssertionError("must not request a token without a session"),
                expected = AndroidRestoredAuthentication("", false)),
            Case("invalid session", expected = AndroidRestoredAuthentication("", false)),
            Case("offline refresh", error = CognitoSessionUnavailableException(UnknownHostException()),
                expected = AndroidRestoredAuthentication("", true, unavailable = true)),
            Case("cancellation", error = cancelled),
            Case("programmer error", error = invalidState),
        )) {
            val result = runCatching {
                restoreAndroidAuthentication(case.hasStoredSession) {
                    case.error?.let { throw it }
                    case.token
                }
            }
            if (case.expected != null) assertEquals(case.name, case.expected, result.getOrThrow())
            else assertSame(case.name, case.error, result.exceptionOrNull())
        }
    }
}
