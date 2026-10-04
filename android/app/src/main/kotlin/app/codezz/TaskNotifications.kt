package app.codezz

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Task notifications: one ongoing "running" notification (owned by
 * [TaskProgressService] so the connection survives in the background) and
 * one notification per finished task. Tapping either opens the app with the
 * notification's payload ("deviceId|workspaceKey|taskId").
 */
object TaskNotifications {
    const val EXTRA_PAYLOAD = "codezz.payload"
    const val PROGRESS_ID = 1
    private const val CHANNEL_RUNNING = "running"
    private const val CHANNEL_DONE = "done"

    fun ensureChannels(context: Context, runningName: String, doneName: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_RUNNING, runningName, NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, doneName, NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

    private fun openApp(context: Context, payload: String?, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
        }
        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** The ongoing notification: [progress] of [max] when known, else indeterminate. */
    fun progress(
        context: Context,
        title: String,
        text: String,
        lines: List<String>,
        progress: Int?,
        max: Int?,
        payload: String?,
    ): Notification {
        val b = builder(context, CHANNEL_RUNNING)
            .setSmallIcon(R.drawable.ic_stat_codezz)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openApp(context, payload, 0))
        if (max != null && max > 0 && progress != null) {
            b.setProgress(max, progress, false)
        } else {
            b.setProgress(0, 0, true)
        }
        if (lines.size > 1) {
            val style = Notification.InboxStyle()
            lines.forEach { style.addLine(it) }
            b.setStyle(style)
        }
        return b.build()
    }

    fun done(context: Context, id: Int, title: String, text: String, payload: String?) {
        val n = builder(context, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_stat_codezz)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(openApp(context, payload, id))
            .build()
        context.getSystemService(NotificationManager::class.java).notify(id, n)
    }
}

/**
 * Keeps the process (and so the device connections) alive while tasks run,
 * showing [TaskNotifications.progress] as its foreground notification.
 */
class TaskProgressService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = latest ?: run {
            stopSelf()
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(TaskNotifications.PROGRESS_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(TaskNotifications.PROGRESS_ID, n)
        }
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 caps dataSync services at 6 hours a day.
        stopSelf()
    }

    companion object {
        /** The notification to show; set before starting / updating. */
        @Volatile
        var latest: Notification? = null

        @Volatile
        var running = false
    }
}
