package com.logseq.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import org.json.JSONObject

internal object AndroidBlockClipboard {
    private const val MIME = "application/logseq"

    fun copy(context: Context, payload: String) {
        val fields = JSONObject(payload)
        val plain = fields.getString("plainText")
        val rich = fields.getString("blocksEDN")
        val item = ClipData.Item(plain, null, Intent().putExtra(MIME, rich), null)
        context.getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData("Logseq", arrayOf("text/plain", MIME), item))
    }

    fun content(context: Context, before: String, start: Int, length: Int): String? {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        val plain = item.coerceToText(context)?.toString() ?: return null
        return JSONObject().put("beforeTitle", before).put("selectionStart", start)
            .put("selectionLength", length).put("plainText", plain)
            .put("blocksEDN", item.intent?.getStringExtra(MIME).orEmpty()).toString()
    }
}
