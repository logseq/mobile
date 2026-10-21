package com.logseq.app.runtime

internal data class AndroidGraphProgress(
    val graphId: String, val graphName: String, val phase: String,
    val completed: Long = 0, val total: Long? = null,
)
