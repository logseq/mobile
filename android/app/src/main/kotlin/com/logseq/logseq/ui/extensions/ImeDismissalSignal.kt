package com.logseq.logseq.ui.extensions

import androidx.compose.runtime.compositionLocalOf
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

internal class ImeDismissalSignal {
    private val mutableStarted = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val started: SharedFlow<Unit> = mutableStarted

    fun notifyStarted() {
        mutableStarted.tryEmit(Unit)
    }
}

internal val LocalImeDismissalSignal = compositionLocalOf<ImeDismissalSignal?> { null }
