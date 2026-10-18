package dev.eko.core

import java.nio.charset.StandardCharsets

object NotificationSanitizer {
    const val KEY_BYTES = 8_192
    const val PACKAGE_BYTES = 512
    const val APP_LABEL_BYTES = 2_048
    const val CATEGORY_BYTES = 128
    private const val TEXT_BYTES = 8_192
    private const val BIG_TEXT_BYTES = 65_536
    private const val MESSAGE_SENDER_BYTES = 4_096
    private const val MESSAGE_TEXT_BYTES = 16_384
    private const val MAX_ARRAY_ITEMS = 64
    private const val TOTAL_BODY_STRING_BYTES = 524_288

    fun sanitize(raw: RawNotification): NotificationContent {
        val truncated = mutableListOf<String>()
        var remaining = TOTAL_BODY_STRING_BYTES

        fun field(pointer: String, value: String?, perValueLimit: Int): String? {
            if (value == null) return null
            val clean = replaceUnpairedSurrogates(value)
            val perValue = truncateUtf8(clean, perValueLimit)
            val aggregate = truncateUtf8(perValue, remaining)
            if (clean != value || perValue != clean || aggregate != perValue) truncated.addOnce(pointer)
            remaining -= utf8Size(aggregate)
            return aggregate
        }

        val title = field("/title", raw.title, TEXT_BYTES)
        val text = field("/text", raw.text, TEXT_BYTES)
        val bigText = field("/big_text", raw.bigText, BIG_TEXT_BYTES)
        val subText = field("/sub_text", raw.subText, TEXT_BYTES)
        val infoText = field("/info_text", raw.infoText, TEXT_BYTES)
        val summaryText = field("/summary_text", raw.summaryText, TEXT_BYTES)

        val lines = raw.textLines?.take(MAX_ARRAY_ITEMS)?.mapIndexed { index, value ->
            field("/text_lines/$index", value, TEXT_BYTES).orEmpty()
        }
        if ((raw.textLines?.size ?: 0) > MAX_ARRAY_ITEMS) truncated.addOnce("/text_lines")

        val messages = raw.messages?.take(MAX_ARRAY_ITEMS)?.mapIndexed { index, message ->
            MessageContent(
                sender = field("/messages/$index/sender", message.sender, MESSAGE_SENDER_BYTES),
                text = field("/messages/$index/text", message.text, MESSAGE_TEXT_BYTES).orEmpty(),
                timestamp = message.timestamp,
            )
        }
        if ((raw.messages?.size ?: 0) > MAX_ARRAY_ITEMS) truncated.addOnce("/messages")

        val groupKey = field("/group_key", raw.groupKey, TEXT_BYTES)
        return NotificationContent(
            title = title,
            text = text,
            bigText = bigText,
            subText = subText,
            infoText = infoText,
            summaryText = summaryText,
            textLines = lines,
            messages = messages,
            isClearable = raw.isClearable,
            isGroupSummary = raw.isGroupSummary,
            groupKey = groupKey,
            truncatedFields = truncated,
        )
    }

    fun withMetadataLimits(content: NotificationContent, label: String, category: String?): Triple<NotificationContent, String, String?> {
        val cleanLabel = replaceUnpairedSurrogates(label).ifEmpty { "?" }
        val limitedLabel = truncateUtf8(cleanLabel, APP_LABEL_BYTES)
        val cleanCategory = category?.let(::replaceUnpairedSurrogates)
        val limitedCategory = cleanCategory?.let { truncateUtf8(it, CATEGORY_BYTES) }
        val metadataPointers = buildList {
            if (limitedLabel != label) add("/app/label")
            if (limitedCategory != category) add("/app/category")
        }
        return Triple(
            content.copy(truncatedFields = (metadataPointers + content.truncatedFields).distinct()),
            limitedLabel,
            limitedCategory,
        )
    }

    fun isValidOpaqueIdentifier(value: String, maxUtf8Bytes: Int): Boolean =
        value.isNotEmpty() && value == replaceUnpairedSurrogates(value) && utf8Size(value) <= maxUtf8Bytes

    fun containsRedactedText(content: NotificationContent, systemRedactionMessage: String?): Boolean {
        val marker = systemRedactionMessage?.trim().orEmpty()
        if (marker.isEmpty()) return false
        return sequenceOf(
            content.title,
            content.text,
            content.bigText,
            content.subText,
            content.infoText,
            content.summaryText,
        ).plus(content.textLines.orEmpty()).plus(content.messages.orEmpty().map(MessageContent::text))
            .filterNotNull()
            .any { it.trim() == marker }
    }

    private fun replaceUnpairedSurrogates(value: String): String {
        val output = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            val current = value[index]
            when {
                Character.isHighSurrogate(current) && index + 1 < value.length && Character.isLowSurrogate(value[index + 1]) -> {
                    output.append(current).append(value[index + 1])
                    index += 2
                }
                Character.isSurrogate(current) -> {
                    output.append('\uFFFD')
                    index++
                }
                else -> {
                    output.append(current)
                    index++
                }
            }
        }
        return output.toString()
    }

    private fun truncateUtf8(value: String, maxBytes: Int): String {
        if (maxBytes <= 0) return ""
        if (utf8Size(value) <= maxBytes) return value
        val result = StringBuilder()
        var used = 0
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val chars = String(Character.toChars(codePoint))
            val size = utf8Size(chars)
            if (used + size > maxBytes) break
            result.append(chars)
            used += size
            index += Character.charCount(codePoint)
        }
        return result.toString()
    }

    private fun utf8Size(value: String): Int = value.toByteArray(StandardCharsets.UTF_8).size

    private fun MutableList<String>.addOnce(pointer: String) {
        if (pointer !in this) add(pointer)
    }
}
