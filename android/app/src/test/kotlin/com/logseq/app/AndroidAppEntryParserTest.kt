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
}
