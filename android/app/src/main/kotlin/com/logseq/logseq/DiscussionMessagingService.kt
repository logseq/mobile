package com.logseq.logseq

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.text.BreakIterator
import java.util.Locale
import java.util.UUID

class DiscussionMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val preferences = AndroidDiscussionPush(this).preferences
        if (!preferences.enabled) return
        when (message.data["kind"]) {
            "comment" -> if (!preferences.comments) return
            "reaction" -> if (!preferences.reactions) return
        }
        showDiscussionNotification(this, message.data)
    }
}

internal fun showDiscussionNotification(context: Context, data: Map<String, String>) {
    fun routeId(key: String): String? = data[key]?.takeIf { value ->
        runCatching { UUID.fromString(value).toString().equals(value, ignoreCase = true) }.getOrDefault(false)
    }
    val graph = routeId("graphId") ?: return
    val event = routeId("eventId") ?: return
    if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
            context, Manifest.permission.POST_NOTIFICATIONS,
        ) != PackageManager.PERMISSION_GRANTED) return

    val body = when (data["kind"]) {
        "comment" -> data["commentPreview"] ?: context.getString(R.string.discussion_push_comment)
        "reaction" -> data["reactionEmoji"]?.let { context.getString(R.string.discussion_push_reaction_emoji, it) }
            ?: context.getString(R.string.discussion_push_reaction)
        else -> context.getString(R.string.discussion_push_body)
    }
    val intent = Intent(context, MainActivity::class.java).apply {
        this.data = Uri.Builder().scheme("logseq").authority("notification").appendPath(event).build()
        putExtra("graphId", graph)
        putExtra("eventId", event)
    }
    val open = PendingIntent.getActivity(context, 0, intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val sender = data["senderName"]?.takeIf { it.isNotBlank() }
    val notification = NotificationCompat.Builder(context, AndroidDiscussionPush.CHANNEL)
        .setSmallIcon(R.mipmap.ic_launcher_monochrome)
        .setContentTitle(sender ?: context.applicationInfo.loadLabel(context.packageManager))
        .setContentText(body)
        .setContentIntent(open)
        .setAutoCancel(true)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
    if (sender != null) {
        val person = Person.Builder().setName(sender).setKey(data["senderId"])
            .setIcon(IconCompat.createWithBitmap(ProfileAvatarCache.image(context, data["avatarURL"]) ?: discussionAvatar(sender))).build()
        notification.setStyle(NotificationCompat.MessagingStyle(
            Person.Builder().setName(context.getString(R.string.discussion_push_you)).build(),
        ).addMessage(body, System.currentTimeMillis(), person))
    }
    val push = AndroidDiscussionPush(context)
    push.createChannel()
    context.getSystemService(NotificationManager::class.java).notify(event, 0, notification.build())
}

private fun discussionAvatar(name: String): Bitmap {
    val iterator = BreakIterator.getCharacterInstance(Locale.getDefault()).apply { setText(name) }
    val initial = name.substring(0, iterator.next()).uppercase(Locale.getDefault())
    val bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(13, 85, 90) }
    canvas.drawCircle(64f, 64f, 64f, paint)
    paint.color = Color.WHITE
    paint.textSize = 58f
    paint.textAlign = Paint.Align.CENTER
    paint.typeface = Typeface.create("sans-serif", Typeface.BOLD)
    canvas.drawText(initial, 64f, 64f - (paint.ascent() + paint.descent()) / 2, paint)
    return bitmap
}
