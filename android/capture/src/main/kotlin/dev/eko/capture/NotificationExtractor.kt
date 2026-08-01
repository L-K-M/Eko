package dev.eko.capture

import android.app.Notification
import android.content.Context
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import dev.eko.core.DndDescriptor
import dev.eko.core.MessageContent
import dev.eko.core.NotificationSanitizer
import dev.eko.core.RawNotification
import dev.eko.outbox.NotificationSnapshot

data class ExtractedNotification(
    val snapshot: NotificationSnapshot?,
    val redacted: Boolean,
    val writerOverflow: Boolean = false,
)

class NotificationExtractor(private val context: Context) {
    fun extract(
        sbn: StatusBarNotification,
        rankingMap: NotificationListenerService.RankingMap?,
        interruptionFilter: Int,
    ): ExtractedNotification? {
        if (sbn.packageName == context.packageName) return null
        val notification = sbn.notification
        val rawContent = extractContent(notification, sbn.isClearable, sbn.groupKey)
        if (!NotificationSanitizer.isValidOpaqueIdentifier(sbn.key, NotificationSanitizer.KEY_BYTES) ||
            !NotificationSanitizer.isValidOpaqueIdentifier(sbn.packageName, NotificationSanitizer.PACKAGE_BYTES)
        ) {
            return ExtractedNotification(null, redacted = false, writerOverflow = true)
        }
        val (content, appLabel, category) = NotificationSanitizer.withMetadataLimits(
            rawContent,
            resolveLabel(sbn),
            notification.category,
        )
        val ranking = NotificationListenerService.Ranking()
        val hasRanking = rankingMap?.getRanking(sbn.key, ranking) == true
        val userId = if (Build.VERSION.SDK_INT >= 29) {
            sbn.uid / PER_USER_UID_RANGE
        } else {
            sbn.user.hashCode()
        }
        val snapshot = NotificationSnapshot(
            key = sbn.key,
            postedAt = sbn.postTime,
            userId = userId,
            packageName = sbn.packageName,
            appLabel = appLabel,
            category = category,
            content = content,
            dnd = DndDescriptor(
                filter = interruptionFilterName(interruptionFilter),
                suppressed = hasRanking && !ranking.matchesInterruptionFilter(),
            ),
            ongoing = notification.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE) != 0,
        )
        return ExtractedNotification(snapshot, NotificationSanitizer.containsRedactedText(content, redactionMarker()))
    }

    internal fun extractContent(
        notification: Notification,
        isClearable: Boolean,
        groupKey: String?,
    ): dev.eko.core.NotificationContent {
        val isGroupSummary = notification.flags and Notification.FLAG_GROUP_SUMMARY != 0
        // The first extras read unparcels the whole Bundle inside this process.
        // A hostile notification can carry a Parcelable our classloader cannot
        // resolve, which throws BadParcelableException (a RuntimeException) from
        // any of these getters. Left unguarded that kills the listener process,
        // and the poisoned notification crashes every reconciliation on restart —
        // a repeatable crash loop. Degrade to metadata-only instead; the event is
        // still captured (key, package, timestamps) with empty content.
        val raw = try {
            RawNotification(
                title = notification.extras.charSequence(Notification.EXTRA_TITLE),
                text = notification.extras.charSequence(Notification.EXTRA_TEXT),
                bigText = notification.extras.charSequence(Notification.EXTRA_BIG_TEXT),
                subText = notification.extras.charSequence(Notification.EXTRA_SUB_TEXT),
                infoText = notification.extras.charSequence(Notification.EXTRA_INFO_TEXT),
                summaryText = notification.extras.charSequence(Notification.EXTRA_SUMMARY_TEXT),
                textLines = notification.extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                    ?.map(CharSequence::toString),
                messages = runCatching {
                    NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(notification)
                        ?.messages
                        ?.map { message ->
                            MessageContent(
                                sender = message.person?.name?.toString(),
                                text = message.text.toString(),
                                timestamp = message.timestamp.takeIf { it in 0..9_007_199_254_740_991L },
                            )
                        }
                }.getOrNull(),
                isClearable = isClearable,
                isGroupSummary = isGroupSummary,
                groupKey = groupKey,
            )
        } catch (error: RuntimeException) {
            CaptureDiagnostics.get(context).extractionFailure(error.javaClass.simpleName ?: "unknown")
            RawNotification(
                isClearable = isClearable,
                isGroupSummary = isGroupSummary,
                groupKey = groupKey,
            )
        }
        return NotificationSanitizer.sanitize(raw)
    }

    private fun resolveLabel(sbn: StatusBarNotification): String = runCatching {
        val info = context.packageManager.getApplicationInfo(sbn.packageName, 0)
        context.packageManager.getApplicationLabel(info).toString()
    }.getOrDefault(sbn.packageName)

    // The framework string this compares against cannot change while the process
    // lives, but the lookup that finds it is a by-name walk of the framework resource
    // table — an API the platform explicitly documents as slow and discourages — and it
    // was running once per notification on the listener's main thread, and once per
    // active notification during a full reconciliation. Resolve it once.
    private val redactionMarkerValue: String? by lazy {
        val system = android.content.res.Resources.getSystem()
        val id = system.getIdentifier("redacted_notification_message", "string", "android")
        if (id == 0) null else runCatching { system.getString(id) }.getOrNull()
    }

    private fun redactionMarker(): String? = redactionMarkerValue

    private fun interruptionFilterName(filter: Int): String = when (filter) {
        NotificationListenerService.INTERRUPTION_FILTER_ALL -> "all"
        NotificationListenerService.INTERRUPTION_FILTER_PRIORITY -> "priority"
        NotificationListenerService.INTERRUPTION_FILTER_NONE -> "none"
        NotificationListenerService.INTERRUPTION_FILTER_ALARMS -> "alarms"
        else -> "unknown"
    }

    private fun android.os.Bundle.charSequence(key: String): String? =
        getCharSequence(key)?.toString()

    private companion object {
        // Android allocates each user a 100,000-wide application UID range.
        const val PER_USER_UID_RANGE = 100_000
    }
}
