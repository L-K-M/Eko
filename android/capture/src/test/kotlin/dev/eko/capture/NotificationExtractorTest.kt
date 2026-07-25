package dev.eko.capture

import android.app.Notification
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class NotificationExtractorTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val extractor = NotificationExtractor(context)

    @Test
    fun `keeps extras as distinct structured fields`() {
        val notification = Notification.Builder(context, "test")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Title")
            .setContentText("Text")
            .setSubText("Sub")
            .setStyle(Notification.BigTextStyle().bigText("Big text").setSummaryText("Summary"))
            .build()
            .also {
                it.extras.putCharSequence(Notification.EXTRA_INFO_TEXT, "Info")
                it.extras.putCharSequenceArray(Notification.EXTRA_TEXT_LINES, arrayOf("One", "Two"))
            }

        val content = extractor.extractContent(notification, isClearable = true, groupKey = "group")

        assertEquals("Title", content.title)
        assertEquals("Text", content.text)
        assertEquals("Big text", content.bigText)
        assertEquals("Sub", content.subText)
        assertEquals("Info", content.infoText)
        assertEquals("Summary", content.summaryText)
        assertEquals(listOf("One", "Two"), content.textLines)
        assertEquals("group", content.groupKey)
    }

    @Test
    fun `extracts MessagingStyle messages without flattening senders`() {
        val sender = Person.Builder().setName("Ada").build()
        val notification = NotificationCompat.Builder(context, "test")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setStyle(
                NotificationCompat.MessagingStyle(Person.Builder().setName("Me").build())
                    .addMessage("Code 123456", 42L, sender),
            )
            .build()

        val content = extractor.extractContent(notification, isClearable = true, groupKey = null)

        assertEquals(1, content.messages?.size)
        assertEquals("Ada", content.messages?.single()?.sender)
        assertEquals("Code 123456", content.messages?.single()?.text)
        assertEquals(42L, content.messages?.single()?.timestamp)
    }

    @Test
    fun `marks group summaries and clearability independently`() {
        val notification = Notification.Builder(context, "test")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setGroup("group")
            .setGroupSummary(true)
            .build()
        val content = extractor.extractContent(notification, isClearable = false, groupKey = "group")

        assertTrue(content.isGroupSummary)
        assertFalse(content.isClearable)
    }
}
