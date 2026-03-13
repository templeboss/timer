package com.example.timer_app

import android.content.Context
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the timer/notifications MethodChannel on the background Flutter engine
 * created by flutter_foreground_task.  This allows the background Dart isolate to call
 * AlarmNotificationHelper just like the main isolate does.
 */
class TimerBackgroundEngineListener(private val context: Context) :
    FlutterForegroundTaskLifecycleListener {

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        flutterEngine ?: return
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "timer/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showAlarm" -> {
                        val name = call.argument<String>("name") ?: "Timer"
                        AlarmNotificationHelper.show(context, name)
                        result.success(null)
                    }
                    "cancelAlarm" -> {
                        AlarmNotificationHelper.cancel(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
    override fun onTaskRepeatEvent() {}
    override fun onTaskDestroy() {}
    override fun onEngineWillDestroy() {}
}
