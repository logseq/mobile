package com.logseq.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
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
