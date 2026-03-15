package com.example.timer_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.pravera.flutter_foreground_task.service.ForegroundService

class DismissAlarmReceiver : BroadcastReceiver() {

    companion object {
        var onDismiss: (() -> Unit)? = null

        // SharedPreferences file/key used by Flutter's shared_preferences plugin.
        private const val PREFS_FILE = "FlutterSharedPreferences"
        const val KEY_DISMISS_PENDING = "flutter.alarm_dismissed_pending"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AlarmNotificationHelper.ACTION_DISMISS) return

        AlarmNotificationHelper.cancel(context)

        // Notify the main Flutter engine (if alive)
        onDismiss?.invoke()

        // Notify the background task (if running) so it resets MQTT state.
        // If the service isn't running yet (e.g. process just restarted) sendData
        // is a no-op, so we also write a SharedPreferences flag that the
        // background task reads in onStart() as a fallback.
        ForegroundService.sendData("dismiss")
        context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_DISMISS_PENDING, true)
            .apply()
    }
}
