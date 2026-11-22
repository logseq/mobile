package com.logseq.logseq

import android.net.Uri
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

internal object AndroidAppEntryParser {
    fun deepLink(value: String?): Map<String, Any?>? {
        val uri = value?.let { runCatching { URI(it) }.getOrNull() } ?: return null
        fun decode(value: String) = URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8.name())
        val query = uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).map { item ->
            val pair = item.split('=', limit = 2)
            mapOf("name" to decode(pair[0]), "value" to pair.getOrNull(1)?.let(::decode))
        }
        return mapOf("kind" to "deep-link", "scheme" to uri.scheme, "host" to uri.host, "path" to decode(uri.rawPath.orEmpty()), "query" to query)
    }
    fun initialWidgetBlock(value: String?): Map<String, Any?>? {
        val uri = value?.let(Uri::parse) ?: return null
        if (uri.scheme != "logseq" || uri.host != "graph" ||
            uri.getQueryParameter("widget-action") != "open-block" ||
            uri.getQueryParameter("block-id").isNullOrEmpty()
        ) return null
        return deepLink(value)
    }

    fun blockURL(graphName: String, blockID: String): String =
        URI("logseq", "graph", "/$graphName", "block-id=$blockID", null).toASCIIString()
}
