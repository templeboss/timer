package com.example.timer_app

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat

object AlarmNotificationHelper {
    const val CHANNEL_ID = "alarm_channel"
    const val NOTIFICATION_ID = 1
    const val ACTION_DISMISS = "DISMISS_ALARM"

    fun show(context: Context, timerName: String) {
        val dismissIntent = Intent(context, DismissAlarmReceiver::class.java).apply {
            action = ACTION_DISMISS
        }
        val dismissPi = PendingIntent.getBroadcast(
            context, 0, dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Tapping the notification body opens the app
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openPi = PendingIntent.getActivity(
            context, 1, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(timerName)
            .setContentText("Timer elapsed")
            .setContentIntent(openPi)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSound(null)
            .setVibrate(longArrayOf(0, 300, 200, 300))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .addAction(0, "Dismiss", dismissPi)  // 0 = no icon
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notification)
    }

    fun cancel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
    }
}
