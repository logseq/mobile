package com.logseq.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class AuthenticationActivityContractTest {
    @Test
    fun `android app is distinguishable from the existing Logseq app`() {
        val application = manifest().documentElement

        assertEquals(
            "Logseq",
            application.getElementsByTagName("application")
                .item(0)
                .let { it as Element }
                .getAttributeNS(androidNamespace, "label")
        )
    }

    @Test
    fun `incoming app entries reuse the existing activity`() {
        val activity = mainActivity()

        assertEquals(
            "singleTask",
            activity.getAttributeNS(androidNamespace, "launchMode")
        )
    }

    @Test
    fun `password login does not expose an OAuth callback`() {
        val activity = mainActivity()
        val dataElements = activity.getElementsByTagName("data")
        val hasOAuthCallback = (0 until dataElements.length).any { index ->
            val data = dataElements.item(index) as Element
            data.getAttributeNS(androidNamespace, "scheme") == "logseq" &&
                data.getAttributeNS(androidNamespace, "host") == "auth" &&
                data.getAttributeNS(androidNamespace, "pathPrefix") == "/callback"
        }

        org.junit.Assert.assertFalse("Password login does not use browser callbacks", hasOAuthCallback)
    }

    @Test
    fun `cleartext networking is limited to the local development backend`() {
        val application = manifest().documentElement
            .getElementsByTagName("application")
            .item(0) as Element
        assertEquals(
            "@xml/network_security_config",
            application.getAttributeNS(androidNamespace, "networkSecurityConfig"),
        )

        val config = DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(File("src/main/res/xml/network_security_config.xml"))
        val baseConfig = config.getElementsByTagName("base-config").item(0) as Element
        assertEquals("false", baseConfig.getAttribute("cleartextTrafficPermitted"))
        val domains = config.getElementsByTagName("domain")
        val localDomains = (0 until domains.length)
            .map { domains.item(it).textContent.trim() }
            .toSet()
        assertEquals(setOf("127.0.0.1", "localhost"), localDomains)
    }

    @Test
    fun `debug builds allow user configured LAN development backends`() {
        val config = DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(File("src/debug/res/xml/network_security_config.xml"))
        val baseConfig = config.getElementsByTagName("base-config").item(0) as Element

        assertEquals("true", baseConfig.getAttribute("cleartextTrafficPermitted"))
    }

    private fun mainActivity(): Element {
        val document = manifest()
        val activities = document.getElementsByTagName("activity")
        return (0 until activities.length)
            .map { activities.item(it) as Element }
            .first {
                it.getAttributeNS(androidNamespace, "name") == ".MainActivity"
            }
    }

    private fun manifest() = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
    }.newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))

    private companion object {
        const val androidNamespace = "http://schemas.android.com/apk/res/android"
    }
}
