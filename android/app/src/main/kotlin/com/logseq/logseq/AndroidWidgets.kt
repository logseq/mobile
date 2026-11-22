package com.logseq.logseq

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.icu.text.BreakIterator
import android.util.AtomicFile
import android.util.Log
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import android.widget.Toast
import androidx.core.os.BundleCompat
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
        val pending = goAsync()
        val app = context.applicationContext
        NativeCoreSession.cleanupScope.launch {
            try {
                if (!AndroidBackgroundSync.updateWidgetTaskStatus(app, change)) {
                    Toast.makeText(app, R.string.widget_status_update_failed, Toast.LENGTH_SHORT).show()
                }
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        private const val changeStatusAction = "com.logseq.logseq.widget.CHANGE_TASK_STATUS"

        internal fun selectStatus(context: Context, change: WidgetTaskStatusChange) {
            val data = Uri.Builder().scheme("logseq").authority("widget-status")
                .appendQueryParameter("graph", change.graphId)
                .appendQueryParameter("task", change.uuid)
                .appendQueryParameter("current", change.expectedStatusUuid)
                .appendQueryParameter("next", change.statusUuid)
                .build()
            context.sendBroadcast(Intent(context, TaskListWidgetProvider::class.java)
                .setAction(changeStatusAction).setData(data).addFlags(Intent.FLAG_RECEIVER_FOREGROUND))
        }
    }
}

class RandomBlocksWidgetProvider : GraphWidgetProvider(showsTasks = false) {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != refreshAction) {
            super.onReceive(context, intent)
            return
        }
        val pending = goAsync()
        val app = context.applicationContext
        NativeCoreSession.cleanupScope.launch {
            try {
                AndroidBackgroundSync.refreshRandomWidget(app)
            } finally {
                val manager = AppWidgetManager.getInstance(app)
                val ids = manager.getAppWidgetIds(ComponentName(app, RandomBlocksWidgetProvider::class.java))
                // The cached sample can still rotate if the graph is temporarily unavailable.
                if (ids.isNotEmpty()) onUpdate(app, manager, ids)
                pending.finish()
            }
        }
    }

    companion object {
        private const val refreshAction = "com.logseq.logseq.widget.REFRESH_RANDOM_BLOCKS"

        internal fun refreshIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(context, 0,
                Intent(context, RandomBlocksWidgetProvider::class.java).setAction(refreshAction),
                PendingIntent.FLAG_IMMUTABLE)
    }
}

abstract class GraphWidgetProvider(private val showsTasks: Boolean) : AppWidgetProvider() {
    private val itemLimit = 10
    private val rowHeight = 22
    private val rowPadding = 4
    private val rowTextSize = 15f

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val content = AndroidWidgetContent.read(context)
        val graphId = content?.optString("graphId")?.takeIf(String::isNotEmpty)
        val graphLocked = content?.optBoolean("graphLocked") == true
        val rows = content?.optJSONArray(if (showsTasks) "tasks" else "randomBlocks")
        val entries = (0 until (rows?.length() ?: 0)).mapNotNull { rows?.optJSONObject(it) }
        val eligible = if (showsTasks) entries else entries.filter { block ->
            val text = block.optString("title").trim()
            val characters = BreakIterator.getCharacterInstance().apply { setText(text) }
            characters.next(5) != BreakIterator.DONE
        }.shuffled()
        val blocks = eligible.take(itemLimit)
        val metrics = context.resources.displayMetrics
        val titleHeight = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, rowTextSize, metrics) * 1.2f / metrics.density
        val rowSlot = maxOf(rowHeight.toFloat(), titleHeight) + 2 * rowPadding
        for (widgetId in appWidgetIds) {
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            val views = graphViews(context, options) { height ->
                // The layout reserves 36dp for the header and 20dp for padding.
                val rowLimit = ((height - 56) / rowSlot).toInt().coerceAtLeast(1)
                blockList(context, widgetId, graphId, graphLocked, blocks.take(rowLimit))
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        onUpdate(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    private fun graphViews(context: Context, options: Bundle, render: (Float) -> RemoteViews): RemoteViews {
        if (Build.VERSION.SDK_INT >= 31) {
            val sizes = BundleCompat.getParcelableArrayList(options, AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
            if (!sizes.isNullOrEmpty()) {
                return RemoteViews(sizes.associateWith { render(it.height) })
            }
        }
        val landscape = context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val heightKey = if (landscape) AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT
        return render(options.getInt(heightKey, 158).toFloat())
    }

    private fun blockList(
        context: Context, widgetId: Int, graphId: String?, graphLocked: Boolean, blocks: List<JSONObject>,
    ) = RemoteViews(context.packageName, R.layout.widget_graph).apply {
        setTextViewText(R.id.widget_graph_title, context.getString(
            if (showsTasks) R.string.widget_tasks else R.string.widget_random_blocks
        ))
        setViewVisibility(R.id.widget_graph_add, if (showsTasks || graphId != null) View.VISIBLE else View.GONE)
        if (showsTasks) {
            setOnClickPendingIntent(R.id.widget_graph_add, entryPointIntent(context, "logseq://task", 4))
        } else if (graphId != null) {
            setTextViewText(R.id.widget_graph_add, "⟳")
            setContentDescription(R.id.widget_graph_add, context.getString(R.string.widget_refresh_random_blocks))
            setOnClickPendingIntent(R.id.widget_graph_add, RandomBlocksWidgetProvider.refreshIntent(context))
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
        val padding = (rowPadding * context.resources.displayMetrics.density).toInt()
        if (graphId != null) blocks.forEach { block ->
            addView(R.id.widget_graph_rows, blockRow(context, widgetId, graphId, block, padding))
        }
    }

    private fun blockRow(context: Context, widgetId: Int, graphId: String, block: JSONObject, padding: Int): RemoteViews {
        val title = block.getString("title")
        val link = Uri.Builder().scheme("logseq").authority("graph")
            .appendQueryParameter("graph-id", graphId)
            .appendQueryParameter("block-id", block.getString("uuid"))
            .appendQueryParameter("widget-action", "open-block")
        return RemoteViews(context.packageName, R.layout.widget_graph_row).apply {
            setViewPadding(R.id.widget_graph_row, 0, padding, 0, padding)
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
                setImageViewBitmap(R.id.widget_block_status, widgetStatusIcon(context, block.optJSONObject("statusAppearance")))
                if (current.isNotEmpty() && canChange) {
                    setContentDescription(R.id.widget_block_status,
                        context.getString(R.string.widget_set_status_for, title, status))
                    setOnClickPendingIntent(R.id.widget_block_status, WidgetStatusMenuActivity.open(
                        context, widgetId, graphId, block.getString("uuid"), current
                    ))
                } else {
                    setContentDescription(R.id.widget_block_status, status)
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

    suspend fun refresh(context: Context, callCore: suspend (String) -> String, resampleRandom: Boolean = false) {
        refreshLock.withLock {
            try {
                val payload = if (resampleRandom) JSONObject().put("resampleRandomBlocks", true) else null
                val response = JSONObject(callCore(widgetRequest("widgetSnapshot", payload)))
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
        val previous = read(context)
        if (previous?.toString() == encoded) return
        val file = file(context)
        try {
            val output = file.startWrite()
            try {
                output.write(encoded.encodeToByteArray())
                file.finishWrite(output)
            } catch (error: Exception) {
                file.failWrite(output)
                throw error
            }
            val graphChanged = previous == null ||
                previous.optString("graphId") != content.optString("graphId") ||
                previous.optBoolean("graphLocked") != content.optBoolean("graphLocked")
            val tasksChanged = previous?.optJSONArray("tasks")?.toString() != content.optJSONArray("tasks")?.toString()
            val hadRandomBlocks = (previous?.optJSONArray("randomBlocks")?.length() ?: 0) > 0
            val hasRandomBlocks = (content.optJSONArray("randomBlocks")?.length() ?: 0) > 0
            val providers = buildList {
                if (graphChanged || tasksChanged) add(TaskListWidgetProvider())
                // Once data is available, the launcher updates the random widget on its own schedule.
                val randomVersionChanged = previous?.optInt("randomBlocksVersion") != content.optInt("randomBlocksVersion")
                if (graphChanged || randomVersionChanged || hadRandomBlocks != hasRandomBlocks) {
                    add(RandomBlocksWidgetProvider())
                }
            }
            val manager = AppWidgetManager.getInstance(context)
            for (provider in providers) {
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
