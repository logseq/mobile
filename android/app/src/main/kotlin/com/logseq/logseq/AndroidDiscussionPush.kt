package com.logseq.logseq

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class DiscussionPushPreferences(val enabled: Boolean, val comments: Boolean, val reactions: Boolean) {
    fun json(): JSONObject = JSONObject().put("enabled", enabled).put("comments", comments).put("reactions", reactions)

    companion object {
        fun decode(payload: String): DiscussionPushPreferences = JSONObject(payload).let {
            DiscussionPushPreferences(it.getBoolean("enabled"), it.getBoolean("comments"), it.getBoolean("reactions"))
        }
    }
}

internal const val DISCUSSION_PUSH_UNAVAILABLE = "System notifications are unavailable"

internal class DiscussionPushException(val userMessage: String, cause: Throwable? = null) :
    Exception(userMessage, cause)

internal class AndroidDiscussionPush(private val context: Context) {
    private val storage = context.getSharedPreferences("logseq.discussionPush", Context.MODE_PRIVATE)
    private val registration = Mutex()
    val preferences: DiscussionPushPreferences
        get() = DiscussionPushPreferences(storage.getBoolean("enabled", false),
            storage.getBoolean("comments", true), storage.getBoolean("reactions", true))

    private fun save(value: DiscussionPushPreferences) {
        storage.edit().putBoolean("enabled", value.enabled)
            .putBoolean("comments", value.comments).putBoolean("reactions", value.reactions).apply()
    }

    suspend fun setPreferences(value: DiscussionPushPreferences, baseUrl: String, sessionToken: String?) = registration.withLock {
        if (value.enabled) {
            if (FirebaseApp.getApps(context).isEmpty()) {
                throw DiscussionPushException("This build does not support system notifications")
            }
            if (sessionToken.isNullOrBlank()) {
                throw DiscussionPushException("Sign in to manage system notifications")
            }
            createChannel()
            val activity = context as? MainActivity
            if (!preferences.enabled && Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                    context, Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                if (activity?.requestDiscussionNotificationPermission() != true) {
                    throw DiscussionPushException("Allow notifications in system settings")
                }
            }
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                throw DiscussionPushException("Allow notifications in system settings")
            }
            sendRegistration(registrationToken(), value, baseUrl, sessionToken)
        } else if (preferences.enabled) {
            if (sessionToken.isNullOrBlank()) {
                throw DiscussionPushException("Sign in to manage system notifications")
            }
            sendRegistration(null, value, baseUrl, sessionToken)
        }
        save(value)
    }

    suspend fun refresh(baseUrl: String, sessionToken: String) = registration.withLock {
        val value = preferences
        if (!value.enabled) return@withLock
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            sendRegistration(null, value, baseUrl, sessionToken)
            save(value.copy(enabled = false))
        } else {
            sendRegistration(registrationToken(), value, baseUrl, sessionToken)
        }
    }

    suspend fun signOut(baseUrl: String, sessionToken: String) = registration.withLock {
        val value = preferences
        if (!value.enabled) return@withLock
        try {
            sendRegistration(null, value, baseUrl, sessionToken)
        } finally {
            save(value.copy(enabled = false))
            if (FirebaseApp.getApps(context).isNotEmpty()) FirebaseMessaging.getInstance().deleteToken()
        }
    }

    fun createChannel() {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL, context.getString(R.string.discussion_notifications), NotificationManager.IMPORTANCE_DEFAULT,
        ))
    }

    private suspend fun registrationToken(): String = withTimeoutOrNull(12_000) {
        suspendCancellableCoroutine { continuation ->
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (task.isSuccessful) continuation.resume(task.result)
                else continuation.resumeWithException(DiscussionPushException(DISCUSSION_PUSH_UNAVAILABLE, task.exception))
            }
        }
    } ?: throw DiscussionPushException(DISCUSSION_PUSH_UNAVAILABLE)

    private suspend fun sendRegistration(
        deviceToken: String?, value: DiscussionPushPreferences, baseUrl: String, sessionToken: String,
    ) {
        val installationId = storage.getString("installation", null) ?: UUID.randomUUID().toString().also {
            storage.edit().putString("installation", it).apply()
        }
        val payload = JSONObject().put("installationId", installationId)
        if (deviceToken != null) payload.put("platform", "fcm").put("token", deviceToken)
            .put("comments", value.comments).put("reactions", value.reactions)
        val request = Request.Builder()
            .url(baseUrl.trimEnd('/') + "/mobile/push-device")
            .header("Authorization", "Bearer $sessionToken")
            .method(if (deviceToken == null) "DELETE" else "PUT", payload.toString().toRequestBody("application/json".toMediaType()))
            .build()
        withContext(Dispatchers.IO) {
            http.newCall(request).execute().use { response ->
                when (response.code) {
                    204 -> Unit
                    401 -> throw DiscussionPushException("Sign in to manage system notifications")
                    404 -> throw DiscussionPushException("This sync server does not support system notifications")
                    else -> throw DiscussionPushException(DISCUSSION_PUSH_UNAVAILABLE)
                }
            }
        }
    }

    companion object {
        const val CHANNEL = "discussions"
        private val http = OkHttpClient.Builder().callTimeout(12, TimeUnit.SECONDS).build()
    }
}
