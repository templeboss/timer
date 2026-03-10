package com.example.timer_app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val ENGINE_ID = "main_engine"
        const val CHANNEL = "timer/notifications"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cache engine so DismissAlarmReceiver can reach it
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)

        // Create notification channel
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                AlarmNotificationHelper.CHANNEL_ID,
                "Timer Alarms",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifies when a timer elapses"
                setSound(null, null)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        // Request POST_NOTIFICATIONS on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0
                )
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showAlarm" -> {
                        val name = call.argument<String>("name") ?: "Timer"
                        AlarmNotificationHelper.show(this, name)
                        result.success(null)
                    }
                    "cancelAlarm" -> {
                        AlarmNotificationHelper.cancel(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Listen for dismiss events sent by DismissAlarmReceiver
        DismissAlarmReceiver.onDismiss = {
            Handler(Looper.getMainLooper()).post {
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod("dismissed", null)
            }
        }
    }

    override fun onDestroy() {
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        DismissAlarmReceiver.onDismiss = null
        super.onDestroy()
    }
}
