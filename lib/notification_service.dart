import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NotificationService {
  static const _channel = MethodChannel('timer/notifications');

  VoidCallback? onDismiss;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'dismissed') onDismiss?.call();
    });
  }

  Future<void> showAlarm(String timerName) async {
    if (!_supported) return;
    await _channel.invokeMethod('showAlarm', {'name': timerName});
  }

  Future<void> cancelAlarm() async {
    if (!_supported) return;
    await _channel.invokeMethod('cancelAlarm');
  }
}
