package com.logseq.app

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CognitoUserPoolTest {
    @Test fun `direct requests use JSON Cognito targets and the public client id`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var operation = ""
        var body = JSONObject()
        server.createContext("/") { exchange ->
            operation = exchange.requestHeaders.getFirst("X-Amz-Target")
            assertEquals("application/x-amz-json-1.1", exchange.requestHeaders.getFirst("Content-Type"))
            body = JSONObject(exchange.requestBody.bufferedReader().readText())
            val response = """{"ChallengeName":"SMS_MFA","Session":"challenge-session"}""".toByteArray()
            exchange.sendResponseHeaders(200, response.size.toLong())
            exchange.responseBody.use { it.write(response) }
        }
        server.start()
        try {
            val transport = CognitoUserPool("test", "public-client", "http://127.0.0.1:${server.address.port}/")
            val response = transport.post("InitiateAuth", JSONObject().put("AuthFlow", "USER_PASSWORD_AUTH"))
            assertEquals("AWSCognitoIdentityProviderService.InitiateAuth", operation)
            assertEquals("public-client", body.getString("ClientId"))
            assertEquals("USER_PASSWORD_AUTH", body.getString("AuthFlow"))
            assertEquals("SMS_MFA", response.getString("ChallengeName"))
            transport.post("AssociateSoftwareToken", JSONObject().put("Session", "setup"))
            assertFalse(body.has("ClientId"))
        } finally { server.stop(0) }
    }

    @Test fun `service errors remain structured without exposing raw details`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val response = """{"__type":"NotAuthorizedException","message":"sensitive service detail"}""".toByteArray()
            exchange.sendResponseHeaders(400, response.size.toLong())
            exchange.responseBody.use { it.write(response) }
        }
        server.start()
        try {
            val transport = CognitoUserPool("test", "client", "http://127.0.0.1:${server.address.port}/")
            val response = transport.post("InitiateAuth", JSONObject())
            assertEquals("NotAuthorizedException", response.getString("__type"))
            assertFalse(response.has("message"))
        } finally { server.stop(0) }
    }
}
