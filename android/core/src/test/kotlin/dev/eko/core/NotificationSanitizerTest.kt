package dev.eko.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NotificationSanitizerTest {
    @Test
    fun `truncation preserves UTF-8 code point boundaries and records fields`() {
        val content = NotificationSanitizer.sanitize(
            RawNotification(
                title = "x".repeat(10_000) + "😀",
                text = null,
                isClearable = true,
                isGroupSummary = false,
            ),
        )

        assertTrue(content.title!!.encodeToByteArray().size <= 8_192)
        assertTrue("/title" in content.truncatedFields)
        assertFalse(content.title.endsWith("�"))
    }

    @Test
    fun `redaction matches the complete system placeholder only`() {
        val marker = "Sensitive notification content hidden"
        val exact = NotificationSanitizer.sanitize(
            RawNotification(text = marker, isClearable = true, isGroupSummary = false),
        )
        val partial = NotificationSanitizer.sanitize(
            RawNotification(text = "Prefix $marker", isClearable = true, isGroupSummary = false),
        )

        assertTrue(NotificationSanitizer.containsRedactedText(exact, marker))
        assertFalse(NotificationSanitizer.containsRedactedText(partial, marker))
        assertEquals(emptyList(), exact.truncatedFields)
    }

    @Test
    fun `aggregate budget follows protocol traversal and records JSON pointers`() {
        val content = NotificationSanitizer.sanitize(
            RawNotification(
                title = "a".repeat(8_192),
                text = "b".repeat(8_192),
                bigText = "c".repeat(65_536),
                textLines = List(64) { "d".repeat(8_192) },
                messages = List(65) { MessageContent("sender", "e".repeat(16_384), 1) },
                isClearable = true,
                isGroupSummary = false,
                groupKey = "group",
            ),
        )
        val total = sequenceOf(
            content.title,
            content.text,
            content.bigText,
            content.subText,
            content.infoText,
            content.summaryText,
            content.groupKey,
        ).filterNotNull().sumOf { it.encodeToByteArray().size } +
            content.textLines.orEmpty().sumOf { it.encodeToByteArray().size } +
            content.messages.orEmpty().sumOf { (it.sender?.encodeToByteArray()?.size ?: 0) + it.text.encodeToByteArray().size }

        assertTrue(total <= 524_288)
        assertTrue("/messages" in content.truncatedFields)
        assertTrue(content.truncatedFields.any { it.startsWith("/text_lines/") })
    }
}
