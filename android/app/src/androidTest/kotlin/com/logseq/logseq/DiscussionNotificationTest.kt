package com.logseq.logseq

import android.app.Notification
import android.app.NotificationManager
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class DiscussionNotificationTest {
    @Test fun showsSenderAvatarAndAppropriatePreview() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, android.Manifest.permission.POST_NOTIFICATIONS)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val graph = "a3fe84fa-72ab-4c5d-b3d9-35630653298c"
        val event = "67449ea2-c708-4b31-8b16-b33a71ec849"
        val fixtures = listOf(
            mapOf("eventId" to event + "1", "kind" to "comment", "senderName" to "Ada",
                "commentPreview" to "I updated the checklist for tomorrow."),
            mapOf("eventId" to event + "2", "kind" to "reaction", "senderName" to "Robin", "reactionEmoji" to "❤️"),
            mapOf("eventId" to event + "3", "kind" to "comment", "senderName" to "Kai"),
        )
        val expected = listOf("I updated the checklist for tomorrow.",
            context.getString(R.string.discussion_push_reaction_emoji, "❤️"), context.getString(R.string.discussion_push_comment))
        fixtures.forEachIndexed { index, fixture ->
            val id = fixture.getValue("eventId")
            showDiscussionNotification(context, fixture + ("graphId" to graph))
            val alert = manager.activeNotifications.single { it.tag == id }.notification
            val message = Notification.MessagingStyle.Message.getMessagesFromBundleArray(
                alert.extras.getParcelableArray(Notification.EXTRA_MESSAGES),
            ).single()
            assertEquals(fixture.getValue("senderName"), message.senderPerson?.name.toString())
            assertNotNull(message.senderPerson?.icon)
            assertEquals(expected[index], message.text.toString())
            assertNotNull(alert.contentIntent)
        }
        if (InstrumentationRegistry.getArguments().getString("keepNotifications") != "true") {
            fixtures.forEach { manager.cancel(it.getValue("eventId"), 0) }
        }
    }
}
