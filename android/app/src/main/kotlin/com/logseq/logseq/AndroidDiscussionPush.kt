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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class AndroidDiscussionPush(private val context: Context) {
    private val preferences = context.getSharedPreferences("logseq.discussionPush", Context.MODE_PRIVATE)
    val enabled: Boolean get() = preferences.getBoolean("enabled", false)

    suspend fun setEnabled(enabled: Boolean, baseUrl: String, sessionToken: String) {
        val firebase = FirebaseApp.getApps(context).firstOrNull()
        val token = if (enabled) {
            check(firebase != null) { "System notifications are unavailable" }
            createChannel()
            val activity = context as? MainActivity
            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                    context, Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                check(activity?.requestDiscussionNotificationPermission() == true) {
                    "Allow notifications in system settings"
                }
            }
            check(NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                "Allow notifications in system settings"
            }
            registrationToken()
        } else null
        sendRegistration(token, baseUrl, sessionToken)
        preferences.edit().putBoolean("enabled", enabled).apply()
    }

    suspend fun refresh(baseUrl: String, sessionToken: String) {
        if (!enabled) return
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            setEnabled(false, baseUrl, sessionToken)
        } else {
            sendRegistration(registrationToken(), baseUrl, sessionToken)
        }
    }

    suspend fun signOut(baseUrl: String, sessionToken: String) {
        if (!enabled) return
        try {
            setEnabled(false, baseUrl, sessionToken)
        } finally {
            preferences.edit().putBoolean("enabled", false).apply()
            if (FirebaseApp.getApps(context).isNotEmpty()) FirebaseMessaging.getInstance().deleteToken()
        }
    }

    private fun createChannel() {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            "discussions", context.getString(R.string.discussion_notifications), NotificationManager.IMPORTANCE_DEFAULT,
        ))
    }

    private suspend fun registrationToken(): String = withTimeout(12_000) {
        suspendCancellableCoroutine { continuation ->
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (task.isSuccessful) continuation.resume(task.result)
                else continuation.resumeWithException(IllegalStateException("System notifications are unavailable", task.exception))
            }
        }
    }

    private suspend fun sendRegistration(deviceToken: String?, baseUrl: String, sessionToken: String) {
        val installationId = preferences.getString("installation", null) ?: UUID.randomUUID().toString().also {
            preferences.edit().putString("installation", it).apply()
        }
        val payload = JSONObject().put("installationId", installationId)
        if (deviceToken != null) payload.put("platform", "fcm").put("token", deviceToken)
        val request = Request.Builder()
            .url(baseUrl.trimEnd('/') + "/mobile/push-device")
            .header("Authorization", "Bearer $sessionToken")
            .method(if (deviceToken == null) "DELETE" else "PUT", payload.toString().toRequestBody("application/json".toMediaType()))
            .build()
        withContext(Dispatchers.IO) {
            http.newCall(request).execute().use { response ->
                check(response.code == 204) { "System notifications are unavailable" }
            }
        }
    }

    companion object {
        private val http = OkHttpClient.Builder().callTimeout(12, TimeUnit.SECONDS).build()
    }
}
