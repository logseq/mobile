package com.logseq.logseq

import kotlinx.coroutines.CancellationException

/** Release every native resource even when a codec or recognition service has failed. */
internal fun releaseAudioResources(vararg releases: () -> Unit): Exception? {
    var failure: Exception? = null
    for (release in releases) {
        try {
            release()
        } catch (error: Exception) {
            if (failure == null) failure = error
            else if (failure !== error) failure.addSuppressed(error)
        }
    }
    return failure
}

/** Automatic stops run in a service coroutine with no UI caller to catch failures. */
internal suspend fun stopAudioCapture(stop: suspend () -> Unit): Exception? = try {
    stop()
    null
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (failure: Exception) {
    failure
}
