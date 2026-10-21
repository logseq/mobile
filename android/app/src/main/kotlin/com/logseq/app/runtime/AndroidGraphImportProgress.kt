package com.logseq.app.runtime

import androidx.annotation.Keep

@Keep
internal object AndroidGraphImportProgress {
    @Volatile var listener: ((String, String, Long, Long?) -> Unit)? = null

    @JvmStatic
    fun receive(graphId: ByteArray, phase: ByteArray, completed: Long, total: Long) {
        listener?.invoke(graphId.toString(Charsets.UTF_8), phase.toString(Charsets.UTF_8),
            completed, total.takeIf { it >= 0 })
    }
}
