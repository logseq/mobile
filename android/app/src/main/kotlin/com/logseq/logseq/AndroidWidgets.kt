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
import org.json.JSONArray
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
        if (intent.action == showStatusesAction) {
            val data = intent.data ?: return
            val widgetId = data.getQueryParameter("widget")?.toIntOrNull() ?: return
            val manager = AppWidgetManager.getInstance(context)
            if (widgetId !in manager.getAppWidgetIds(ComponentName(context, javaClass))) return
            val selection = WidgetStatusSelection(
                data.getQueryParameter("graph") ?: return,
                data.getQueryParameter("task") ?: return,
                data.getQueryParameter("current") ?: return,
                data.getQueryParameter("page")?.toIntOrNull() ?: return,
            )
            if (selection.page < 0) WidgetStatusSelection.clear(context, widgetId)
            else selection.write(context, widgetId)
            onUpdate(context, manager, intArrayOf(widgetId))
            return
        }
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
        val widgetId = data.getQueryParameter("widget")?.toIntOrNull()
        val result = goAsync()
        val app = context.applicationContext
        NativeCoreSession.cleanupScope.launch {
            try {
                if (AndroidBackgroundSync.updateWidgetTaskStatus(app, change)) {
                    if (widgetId != null) {
                        val selection = WidgetStatusSelection.read(app, widgetId)
                        if (selection?.graphId == change.graphId && selection.uuid == change.uuid &&
                            selection.statusUuid == change.expectedStatusUuid
                        ) {
                            WidgetStatusSelection.clear(app, widgetId)
                        }
                        val manager = AppWidgetManager.getInstance(app)
                        if (widgetId in manager.getAppWidgetIds(ComponentName(app, TaskListWidgetProvider::class.java))) {
                            onUpdate(app, manager, intArrayOf(widgetId))
                        }
                    }
                } else {
                    Toast.makeText(app, R.string.widget_status_update_failed, Toast.LENGTH_SHORT).show()
                }
            } finally {
                result.finish()
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        for (widgetId in appWidgetIds) WidgetStatusSelection.clear(context, widgetId)
        super.onDeleted(context, appWidgetIds)
    }

    internal companion object {
        private const val showStatusesAction = "com.logseq.logseq.widget.SHOW_TASK_STATUSES"
        private const val changeStatusAction = "com.logseq.logseq.widget.CHANGE_TASK_STATUS"

        fun showStatuses(context: Context, widgetId: Int, selection: WidgetStatusSelection): PendingIntent =
            widgetStatusIntent(context, showStatusesAction, widgetId,
                selection.graphId, selection.uuid, selection.statusUuid, "page", selection.page.toString())

        fun statusIntent(context: Context, widgetId: Int, change: WidgetTaskStatusChange): PendingIntent =
            widgetStatusIntent(context, changeStatusAction, widgetId,
                change.graphId, change.uuid, change.expectedStatusUuid, "next", change.statusUuid)

        private fun widgetStatusIntent(
            context: Context, actionName: String, widgetId: Int, graphId: String,
            uuid: String, current: String, valueKey: String, value: String,
        ): PendingIntent {
            val intent = Intent(context, TaskListWidgetProvider::class.java).apply {
                action = actionName
                data = Uri.Builder().scheme("logseq").authority("widget-status")
                    .appendQueryParameter("widget", widgetId.toString())
                    .appendQueryParameter("graph", graphId)
                    .appendQueryParameter("task", uuid)
                    .appendQueryParameter("current", current)
                    .appendQueryParameter(valueKey, value)
                    .build()
                addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
            }
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        }
    }
}

internal data class WidgetStatusSelection(
    val graphId: String,
    val uuid: String,
    val statusUuid: String,
    val page: Int,
) {
    fun write(context: Context, widgetId: Int) {
        val data = JSONObject().put("graphId", graphId).put("uuid", uuid)
            .put("statusUuid", statusUuid).put("page", page)
        preferences(context).edit().putString(widgetId.toString(), data.toString()).apply()
    }

    companion object {
        private fun preferences(context: Context) =
            context.getSharedPreferences("widget-task-status-selection", Context.MODE_PRIVATE)

        fun read(context: Context, widgetId: Int): WidgetStatusSelection? {
            val raw = preferences(context).getString(widgetId.toString(), null) ?: return null
            return runCatching {
                val data = JSONObject(raw)
                WidgetStatusSelection(data.getString("graphId"), data.getString("uuid"),
                    data.getString("statusUuid"), data.getInt("page"))
            }.getOrNull()
        }

        fun clear(context: Context, widgetId: Int) {
            preferences(context).edit().remove(widgetId.toString()).apply()
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
        for (widgetId in appWidgetIds) {
            val selection = if (showsTasks) WidgetStatusSelection.read(context, widgetId) else null
            val task = selection?.takeIf { it.graphId == graphId }?.let { selected ->
                blocks.find { it.optString("uuid") == selected.uuid && it.optString("statusUuid") == selected.statusUuid }
            }
            val choices = task?.optJSONArray("statusChoices")
            val views = if (selection != null && task != null && choices != null && choices.length() > 0) {
                statusPicker(context, widgetId, selection, task, choices)
            } else {
                if (selection != null) WidgetStatusSelection.clear(context, widgetId)
                blockList(context, widgetId, graphId, content?.optBoolean("graphLocked") == true, blocks)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun blockList(
        context: Context, widgetId: Int, graphId: String?, graphLocked: Boolean, blocks: List<JSONObject>,
    ) = RemoteViews(context.packageName, R.layout.widget_graph).apply {
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
                graphLocked -> R.string.widget_graph_locked
                graphId == null -> R.string.widget_graph_required
                showsTasks -> R.string.widget_no_tasks
                else -> R.string.widget_no_random_blocks
            }
            setTextViewText(R.id.widget_graph_empty, context.getString(message))
            setOnClickPendingIntent(R.id.widget_graph_empty, entryPointIntent(context, "logseq://journal", 1))
        }
        if (graphId != null) blocks.forEach { block ->
            addView(R.id.widget_graph_rows, blockRow(context, widgetId, graphId, block))
        }
    }

    private fun blockRow(context: Context, widgetId: Int, graphId: String, block: JSONObject): RemoteViews {
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
                val choices = block.optJSONArray("statusChoices")
                val canChange = choices != null && (0 until choices.length()).any { index ->
                    choices.optJSONObject(index)?.optString("uuid")?.let { it != current } == true
                }
                if (current.isNotEmpty() && canChange) {
                    setTextViewText(R.id.widget_block_status, context.getString(R.string.widget_status_action, status))
                    setContentDescription(R.id.widget_block_status,
                        context.getString(R.string.widget_set_status_for, title, status))
                    setOnClickPendingIntent(R.id.widget_block_status, TaskListWidgetProvider.showStatuses(
                        context, widgetId, WidgetStatusSelection(graphId, block.getString("uuid"), current, 0)
                    ))
                } else {
                    setTextViewText(R.id.widget_block_status, status)
                }
            }
        }
    }

    private fun statusPicker(
        context: Context, widgetId: Int, selection: WidgetStatusSelection, task: JSONObject, choices: JSONArray,
    ) = RemoteViews(context.packageName, R.layout.widget_graph).apply {
        val columns = listOf(R.id.widget_status_first, R.id.widget_status_second, R.id.widget_status_third)
        val lastPage = (choices.length() - 1) / 6
        val page = selection.page.coerceIn(0, lastPage)
        setTextViewText(R.id.widget_graph_title, task.getString("title"))
        setViewVisibility(R.id.widget_graph_add, View.VISIBLE)
        setTextViewText(R.id.widget_graph_add, "×")
        setContentDescription(R.id.widget_graph_add, context.getString(android.R.string.cancel))
        setOnClickPendingIntent(R.id.widget_graph_add,
            TaskListWidgetProvider.showStatuses(context, widgetId, selection.copy(page = -1)))
        setViewVisibility(R.id.widget_graph_empty, View.GONE)
        removeAllViews(R.id.widget_graph_rows)
        val end = minOf(choices.length(), page * 6 + 6)
        for (start in page * 6 until end step 3) {
            val row = RemoteViews(context.packageName, R.layout.widget_task_status_row).apply {
                columns.forEachIndexed { offset, id ->
                    val choice = choices.optJSONObject(start + offset).takeIf { start + offset < end }
                    setViewVisibility(id, if (choice == null) View.INVISIBLE else View.VISIBLE)
                    if (choice != null) {
                        val uuid = choice.getString("uuid")
                        val title = choice.getString("title")
                        val selected = uuid == selection.statusUuid
                        setTextViewText(id, if (selected) context.getString(R.string.widget_current_status, title) else title)
                        setContentDescription(id, title)
                        setOnClickPendingIntent(id, TaskListWidgetProvider.statusIntent(
                            context, widgetId, WidgetTaskStatusChange(selection.graphId, selection.uuid, selection.statusUuid, uuid)
                        ))
                    }
                }
            }
            addView(R.id.widget_graph_rows, row)
        }
        if (lastPage > 0) {
            val navigation = RemoteViews(context.packageName, R.layout.widget_task_status_row).apply {
                val previous = columns.first()
                val next = columns.last()
                setViewVisibility(previous, if (page > 0) View.VISIBLE else View.INVISIBLE)
                setTextViewText(previous, context.getString(R.string.widget_status_previous))
                setOnClickPendingIntent(previous, TaskListWidgetProvider.showStatuses(context, widgetId, selection.copy(page = page - 1)))
                setTextViewText(columns[1], context.getString(R.string.widget_status_page, page + 1, lastPage + 1))
                setViewVisibility(next, if (page < lastPage) View.VISIBLE else View.INVISIBLE)
                setTextViewText(next, context.getString(R.string.widget_status_next))
                setOnClickPendingIntent(next, TaskListWidgetProvider.showStatuses(context, widgetId, selection.copy(page = page + 1)))
            }
            addView(R.id.widget_graph_rows, navigation)
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
