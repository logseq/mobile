package com.logseq.logseq

import java.io.File

internal fun resolveAndroidFile(filesDirectory: File, path: String): File {
    val supplied = File(path)
    return if (supplied.isAbsolute) supplied else File(filesDirectory, path)
}
