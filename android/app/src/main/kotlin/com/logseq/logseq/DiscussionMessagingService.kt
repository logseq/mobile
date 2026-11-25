package com.logseq.logseq

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.text.BreakIterator
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit

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
            .setIcon(IconCompat.createWithBitmap(profileAvatar(data["avatarURL"]) ?: discussionAvatar(sender))).build()
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

private val avatarHosts = setOf("logseq-user-public-metadata-bucket-prod.s3.amazonaws.com", "assets.logseq.com", "assets.logseq.io", "avatars.githubusercontent.com", "lh3.googleusercontent.com")
private val avatarClient = OkHttpClient.Builder().callTimeout(2, TimeUnit.SECONDS).followRedirects(false).build()

internal fun profileAvatar(rawUrl: String?): Bitmap? {
    val url = rawUrl?.toHttpUrlOrNull() ?: return null
    if (!url.isHttps || url.host !in avatarHosts || url.port != 443 || url.query != null ||
        url.fragment != null || url.username.isNotEmpty() || url.password.isNotEmpty()) return null
    return try {
        avatarClient.newCall(Request.Builder().url(url).build()).execute().use { response ->
            val body = response.body ?: return null
            val limit = 128L * 1024
            if (response.code != 200 || body.contentType()?.type != "image" || body.contentLength() > limit) return null
            val source = body.source()
            if (source.request(limit + 1)) return null
            val bytes = source.readByteArray()
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val size = maxOf(bounds.outWidth, bounds.outHeight)
            if (size <= 0) return null
            val options = BitmapFactory.Options().apply { inSampleSize = Integer.highestOneBit(maxOf(1, size / 128)) }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        }
    } catch (_: IOException) {
        null
    }
}
