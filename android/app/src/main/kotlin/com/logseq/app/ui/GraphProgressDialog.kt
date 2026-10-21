package com.logseq.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.logseq.app.runtime.AndroidGraphProgress

@Composable
internal fun GraphProgressDialog(progress: AndroidGraphProgress?) {
    if (progress == null) return
    AlertDialog(
        onDismissRequest = {}, confirmButton = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        title = { Text(progress.graphName) },
        text = {
            Column(Modifier.fillMaxWidth().testTag("graph.download.progress"),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(when (progress.phase) {
                    "decoding" -> "Preparing your notes…"
                    "importing" -> "Organizing your notes…"
                    "opening" -> "Opening your graph…"
                    else -> "Getting your notes…"
                })
                val total = progress.total
                if (total != null && total > 0) {
                    LinearProgressIndicator(progress = { (progress.completed.toFloat() / total).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth())
                    Text(if (progress.phase == "downloading")
                        "${progress.completed / 1024} / ${total / 1024} KB"
                        else "${progress.completed} / $total records", style = MaterialTheme.typography.bodySmall)
                } else {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            }
        },
    )
}
