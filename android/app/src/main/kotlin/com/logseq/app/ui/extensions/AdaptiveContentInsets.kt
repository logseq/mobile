package com.logseq.app.ui.extensions

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
internal fun AdaptiveContentInsets(breakpoint: Int, wideInset: Int, content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val inset = if (maxWidth >= breakpoint.dp) wideInset.coerceAtLeast(0).dp else 0.dp
        Box(Modifier.fillMaxSize().padding(horizontal = inset)) { content() }
    }
}
