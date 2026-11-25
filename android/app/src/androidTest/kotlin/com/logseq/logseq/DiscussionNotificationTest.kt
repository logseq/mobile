package com.logseq.logseq

import android.app.Notification
import android.app.NotificationManager
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.util.UUID

class DiscussionNotificationTest {
    @Test fun showsSenderAvatarAndAppropriatePreview() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, android.Manifest.permission.POST_NOTIFICATIONS)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val graph = "a3fe84fa-72ab-4c5d-b3d9-35630653298c"
        val fixtures = listOf(
            mapOf("kind" to "comment", "senderName" to "Ada",
                "commentPreview" to "I updated the checklist for tomorrow."),
            mapOf("kind" to "reaction", "senderName" to "Robin", "reactionEmoji" to "❤️"),
            mapOf("kind" to "comment", "senderName" to "Kai"),
        ).map { it + ("eventId" to UUID.randomUUID().toString()) }
        val expected = listOf("I updated the checklist for tomorrow.",
            context.getString(R.string.discussion_push_reaction_emoji, "❤️"), context.getString(R.string.discussion_push_comment))
        try {
            fixtures.forEachIndexed { index, fixture ->
                val id = fixture.getValue("eventId")
                showDiscussionNotification(context, fixture + ("graphId" to graph))
                val alert = awaitNotification(manager, id)
                val message = Notification.MessagingStyle.Message.getMessagesFromBundleArray(
                    alert.extras.getParcelableArray(Notification.EXTRA_MESSAGES),
                ).single()
                assertEquals(fixture.getValue("senderName"), message.senderPerson?.name.toString())
                assertNotNull(message.senderPerson?.icon)
                assertEquals(expected[index], message.text.toString())
                assertNotNull(alert.contentIntent)
            }
        } finally {
            if (InstrumentationRegistry.getArguments().getString("keepNotifications") != "true") {
                fixtures.forEach { manager.cancel(it.getValue("eventId"), 0) }
            }
        }
    }

    private fun awaitNotification(manager: NotificationManager, id: String): Notification {
        val deadline = SystemClock.elapsedRealtime() + 3_000
        do {
            manager.activeNotifications.firstOrNull { it.tag == id }?.let { return it.notification }
            SystemClock.sleep(20)
        } while (SystemClock.elapsedRealtime() < deadline)
        error("Discussion notification $id was not posted")
    }
}
