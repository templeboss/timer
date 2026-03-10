package com.example.timer_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class DismissAlarmReceiver : BroadcastReceiver() {

    companion object {
        var onDismiss: (() -> Unit)? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AlarmNotificationHelper.ACTION_DISMISS) return

        // Cancel the notification
        AlarmNotificationHelper.cancel(context)

        // Notify Flutter (if engine is alive)
        onDismiss?.invoke()
    }
}
