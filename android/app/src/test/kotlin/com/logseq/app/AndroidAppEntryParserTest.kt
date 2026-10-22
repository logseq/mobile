package com.logseq.app

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidAppEntryParserTest {
    @Test fun preservesDecodedDeepLinkFieldsForTheCore() {
        val value = AndroidAppEntryParser.deepLink("logseq://capture?text=C%2B%2B&text=&title=Example")!!
        assertEquals("logseq", value["scheme"])
        assertEquals("capture", value["host"])
        assertEquals(listOf(mapOf("name" to "text", "value" to "C++"),
            mapOf("name" to "text", "value" to ""), mapOf("name" to "title", "value" to "Example")), value["query"])
    }
    @Test fun graphLinksPreserveDecodedPathAndLiteralPlusSigns() {
        val link = AndroidAppEntryParser.deepLink("logseq://graph/Other%20%E4%B8%AD%E6%96%87%20%2B?page=C%2B%2B+notes&block-id=block")!!
        assertEquals("/Other 中文 +", link["path"])
        assertEquals(listOf(mapOf("name" to "page", "value" to "C+++notes"),
            mapOf("name" to "block-id", "value" to "block")), link["query"])
    }
    @Test fun copiedGraphURLsRoundTripUnicodeAndSpaces() {
        val url = AndroidAppEntryParser.blockURL("Other 中文 +", "block")
        org.junit.Assert.assertFalse(url.contains(" "))
        assertEquals("/Other 中文 +", AndroidAppEntryParser.deepLink(url)!!["path"])
    }
}
