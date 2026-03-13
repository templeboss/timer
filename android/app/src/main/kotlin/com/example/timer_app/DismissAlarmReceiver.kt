package com.example.timer_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.pravera.flutter_foreground_task.service.ForegroundService

class DismissAlarmReceiver : BroadcastReceiver() {

    companion object {
        var onDismiss: (() -> Unit)? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AlarmNotificationHelper.ACTION_DISMISS) return

        AlarmNotificationHelper.cancel(context)

        // Notify the main Flutter engine (if alive)
        onDismiss?.invoke()

        // Notify the background task (if running) so it stops the sound
        ForegroundService.sendData("dismiss")
    }
}
