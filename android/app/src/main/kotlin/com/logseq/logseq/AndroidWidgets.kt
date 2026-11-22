package com.logseq.logseq

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.icu.text.BreakIterator
import android.util.AtomicFile
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import android.widget.Toast
import com.logseq.logseq.runtime.AndroidBackgroundSync
import com.logseq.logseq.runtime.NativeCoreSession
import com.logseq.logseq.runtime.WidgetTaskStatusChange
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private fun entryPointIntent(
    context: Context,
    deepLink: String,
    requestCode: Int,
): PendingIntent {
    val intent = Intent(context, MainActivity::class.java).apply {
        action = Intent.ACTION_VIEW
        data = Uri.parse(deepLink)
        flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
    }
    return PendingIntent.getActivity(
        context,
        requestCode,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

class TodayJournalWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val monthDay = SimpleDateFormat("MMM d", Locale.getDefault()).format(Date())
        val weekday = SimpleDateFormat("EEEE", Locale.getDefault()).format(Date())
        appWidgetIds.forEach { appWidgetId ->
            val views = RemoteViews(context.packageName, R.layout.widget_today_journal).apply {
                setTextViewText(R.id.widget_journal_date, monthDay)
                setTextViewText(R.id.widget_journal_weekday, weekday)
                setOnClickPendingIntent(
                    R.id.widget_journal_root,
                    entryPointIntent(context, "logseq://journal", journalRequestCode),
                )
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private companion object {
        const val journalRequestCode = 1
    }
}

class CaptureWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { appWidgetId ->
            val views = RemoteViews(context.packageName, R.layout.widget_capture).apply {
                setInt(R.id.widget_capture_audio, "setColorFilter", context.getColor(R.color.widget_on_surface))
                setOnClickPendingIntent(
                    R.id.widget_capture_root,
                    entryPointIntent(context, "logseq://capture", captureRequestCode),
                )
                setOnClickPendingIntent(
                    R.id.widget_capture_audio,
                    entryPointIntent(context, "logseq://audio", 3),
                )
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private companion object {
        const val captureRequestCode = 2
    }
}

class TaskListWidgetProvider : GraphWidgetProvider(showsTasks = true) {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != changeStatusAction) {
            super.onReceive(context, intent)
            return
        }
        val data = intent.data ?: return
        val change = WidgetTaskStatusChange(
            data.getQueryParameter("graph") ?: return,
            data.getQueryParameter("task") ?: return,
            data.getQueryParameter("current") ?: return,
            data.getQueryParameter("next") ?: return,
        )
        val result = goAsync()
        val app = context.applicationContext
        NativeCoreSession.cleanupScope.launch {
            try {
                if (!AndroidBackgroundSync.updateWidgetTaskStatus(app, change)) {
                    Toast.makeText(app, R.string.widget_status_update_failed, Toast.LENGTH_SHORT).show()
                }
            } finally {
                result.finish()
            }
        }
    }

    internal companion object {
        private const val changeStatusAction = "com.logseq.logseq.widget.CHANGE_TASK_STATUS"

        fun statusIntent(context: Context, change: WidgetTaskStatusChange): PendingIntent {
            val intent = Intent(context, TaskListWidgetProvider::class.java).apply {
                action = changeStatusAction
                data = Uri.Builder().scheme("logseq").authority("widget-status")
                    .appendQueryParameter("graph", change.graphId)
                    .appendQueryParameter("task", change.uuid)
                    .appendQueryParameter("current", change.expectedStatusUuid)
                    .appendQueryParameter("next", change.statusUuid)
                    .build()
                addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
            }
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
class RandomBlocksWidgetProvider : GraphWidgetProvider(showsTasks = false)

abstract class GraphWidgetProvider(private val showsTasks: Boolean) : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val content = AndroidWidgetContent.read(context)
        val graphId = content?.optString("graphId")?.takeIf(String::isNotEmpty)
        val rows = content?.optJSONArray(if (showsTasks) "tasks" else "randomBlocks")
        val entries = (0 until (rows?.length() ?: 0)).mapNotNull { rows?.optJSONObject(it) }
        val blocks = if (showsTasks) entries.take(3) else entries.filter { block ->
            val text = block.optString("title").trim()
            val characters = BreakIterator.getCharacterInstance().apply { setText(text) }
            characters.next(5) != BreakIterator.DONE
        }.shuffled().take(3)
        val views = RemoteViews(context.packageName, R.layout.widget_graph).apply {
            setTextViewText(R.id.widget_graph_title, context.getString(
                if (showsTasks) R.string.widget_tasks else R.string.widget_random_blocks
            ))
            setViewVisibility(R.id.widget_graph_add, if (showsTasks) View.VISIBLE else View.GONE)
            if (showsTasks) {
                setOnClickPendingIntent(R.id.widget_graph_add, entryPointIntent(context, "logseq://task", 4))
            }
            removeAllViews(R.id.widget_graph_rows)
            val empty = graphId == null || blocks.isEmpty()
            setViewVisibility(R.id.widget_graph_empty, if (empty) View.VISIBLE else View.GONE)
            if (empty) {
                val message = when {
                    graphId == null -> R.string.widget_graph_required
                    showsTasks -> R.string.widget_no_tasks
                    else -> R.string.widget_no_random_blocks
                }
                setTextViewText(R.id.widget_graph_empty, context.getString(message))
                setOnClickPendingIntent(R.id.widget_graph_empty, entryPointIntent(context, "logseq://journal", 1))
            }
            if (graphId != null) blocks.forEach { block ->
                addView(R.id.widget_graph_rows, blockRow(context, graphId, block))
            }
        }
        appWidgetManager.updateAppWidget(appWidgetIds, views)
    }

    private fun blockRow(context: Context, graphId: String, block: JSONObject): RemoteViews {
        val title = block.getString("title")
        val link = Uri.Builder().scheme("logseq").authority("graph")
            .appendQueryParameter("graph-id", graphId)
            .appendQueryParameter("block-id", block.getString("uuid"))
        return RemoteViews(context.packageName, R.layout.widget_graph_row).apply {
            setTextViewText(R.id.widget_block_title, title)
            setOnClickPendingIntent(R.id.widget_block_title, entryPointIntent(context, link.build().toString(), 5))
            setViewVisibility(R.id.widget_block_status, if (showsTasks) View.VISIBLE else View.GONE)
            if (showsTasks) {
                val status = block.getString("status")
                val current = block.optString("statusUuid")
                val next = block.optString("nextStatusUuid")
                if (current.isNotEmpty() && next.isNotEmpty()) {
                    setTextViewText(R.id.widget_block_status, context.getString(R.string.widget_status_action, status))
                    setContentDescription(R.id.widget_block_status,
                        context.getString(R.string.widget_set_status_for, title, status, block.getString("nextStatus")))
                    setOnClickPendingIntent(R.id.widget_block_status, TaskListWidgetProvider.statusIntent(
                        context, WidgetTaskStatusChange(graphId, block.getString("uuid"), current, next)
                    ))
                } else {
                    setTextViewText(R.id.widget_block_status, status)
                }
            }
        }
    }
}

internal object AndroidWidgetContent {
    private val refreshLock = Mutex()
    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "widget-content.json"))

    fun read(context: Context): JSONObject? =
        runCatching { JSONObject(file(context).readFully().decodeToString()) }.getOrNull()

    suspend fun refresh(context: Context, callCore: suspend (String) -> String) {
        refreshLock.withLock {
            try {
                val response = JSONObject(callCore(widgetRequest("widgetSnapshot")))
                if (response.optBoolean("ok")) publish(context, response.getJSONObject("result"))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.w("LogseqWidgets", "Could not refresh widget content", error)
            }
        }
    }

    private fun publish(context: Context, content: JSONObject) {
        val encoded = content.toString()
        val file = file(context)
        if (runCatching { file.readFully().decodeToString() }.getOrNull() == encoded) return
        try {
            val output = file.startWrite()
            try {
                output.write(encoded.encodeToByteArray())
                file.finishWrite(output)
            } catch (error: Exception) {
                file.failWrite(output)
                throw error
            }
            val manager = AppWidgetManager.getInstance(context)
            for (provider in listOf(TaskListWidgetProvider(), RandomBlocksWidgetProvider())) {
                val ids = manager.getAppWidgetIds(ComponentName(context, provider.javaClass))
                if (ids.isNotEmpty()) provider.onUpdate(context, manager, ids)
            }
        } catch (error: Exception) {
            Log.w("LogseqWidgets", "Could not publish widget content", error)
        }
    }
}

internal fun widgetRequest(action: String, payload: JSONObject? = null): String =
    JSONObject().put("apiVersion", 1).put("method", "dispatch")
        .put("params", JSONObject().put("action", action).put("payload", payload?.toString()))
        .toString()
