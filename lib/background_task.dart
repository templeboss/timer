import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
void startBackgroundTask() {
  FlutterForegroundTask.setTaskHandler(BackgroundAlarmTaskHandler());
}

class BackgroundAlarmTaskHandler extends TaskHandler {
  MqttServerClient? _client;
  final Map<String, bool> _wasElapsed = {};
  final Map<String, Timer> _countdowns = {};
  String? _roomCode;
  bool _alarmFiring = false;
  // True until the main isolate tells us the app went to background.
  // Prevents re-triggering alarms that already fired while in the foreground.
  bool _appInForeground = true;
  List<Map<String, dynamic>> _lastState = [];
  // Set when a dismiss arrives before MQTT state is loaded (race condition on
  // service restart). Cleared once we publish the reset to MQTT.
  bool _dismissPending = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final prefs = await SharedPreferences.getInstance();

    // Pick up any dismiss that was stored by DismissAlarmReceiver while this
    // service was not yet running (e.g. killed by battery optimizer).
    if (prefs.getBool('alarm_dismissed_pending') == true) {
      _dismissPending = true;
      await prefs.remove('alarm_dismissed_pending');
    }

    final host = prefs.getString('mqtt_host') ?? '';
    final user = prefs.getString('mqtt_user') ?? '';
    final pass = prefs.getString('mqtt_pass') ?? '';
    _roomCode = prefs.getString('mqtt_room') ?? '';
    final ws = prefs.getBool('mqtt_ws') ?? false;

    if (host.isNotEmpty && user.isNotEmpty && _roomCode!.isNotEmpty) {
      await _connectMqtt(host, user, pass, _roomCode!, ws);
    }
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // autoReconnect on the MQTT client handles reconnection; nothing to do here.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    for (final t in _countdowns.values) {
      t.cancel();
    }
    try {
      _client?.disconnect();
    } catch (_) {}
  }

  // ── Communication with the main isolate ───────────────────────────────────

  @override
  void onReceiveData(Object data) {
    // 'dismiss' string is sent by DismissAlarmReceiver via ForegroundService.sendData
    if (data == 'dismiss') {
      _dismiss();
      return;
    }
    if (data is! Map) return;
    final event = data['event'] as String?;

    if (event == 'background') {
      _appInForeground = false;
      // Sync the known wasElapsed state so we don't re-fire alarms that
      // already fired while the app was in the foreground.
      final state = data['state'];
      if (state is Map) {
        state.forEach((id, val) {
          if (id is String && val is bool) _wasElapsed[id] = val;
        });
      }
      // Schedule local countdowns for any timer that is currently running.
      for (final t in _lastState) {
        final id = t['id'] as String? ?? '';
        final isRunning = t['isRunning'] as bool? ?? false;
        final wasElapsed = _wasElapsed[id] ?? false;
        if (isRunning && !wasElapsed) _scheduleCountdown(t);
      }
    } else if (event == 'foreground') {
      _appInForeground = true;
      // Cancel local countdowns — the main isolate's ticker takes over.
      for (final t in _countdowns.values) {
        t.cancel();
      }
      _countdowns.clear();
      // Hand the ringing alarm over to the main isolate.
      if (_alarmFiring) {
        final name = _lastState
            .firstWhere(
              (t) => t['wasElapsed'] as bool? ?? false,
              orElse: () => <String, dynamic>{},
            )['name'] as String?;
        _handoverAlarm(name);
      }
    } else if (event == 'foreground_startup') {
      // Same as 'foreground' but silently cancels any stale alarm rather than
      // handing it over — avoids replaying an alarm from a previous session.
      _appInForeground = true;
      for (final t in _countdowns.values) {
        t.cancel();
      }
      _countdowns.clear();
      if (_alarmFiring) _clearAlarm();
    }
  }

  // ── MQTT ──────────────────────────────────────────────────────────────────

  Future<void> _connectMqtt(
      String host, String user, String pass, String room, bool ws) async {
    final port = ws ? 8884 : 8883;
    final clientId = 'wt_bg_${DateTime.now().millisecondsSinceEpoch}';
    final client = MqttServerClient.withPort(host, clientId, port);
    client.secure = true;
    client.useWebSocket = ws;
    client.keepAlivePeriod = 30;
    client.connectTimeoutPeriod = 10000;
    client.autoReconnect = true;
    client.logging(on: false);
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(user, pass)
        .startClean();
    client.onAutoReconnected = () {
      client.subscribe('wt/$room/state', MqttQos.atLeastOnce);
    };

    try {
      final result = await client.connect();
      if (result?.state == MqttConnectionState.connected) {
        _client = client;
        client.subscribe('wt/$room/state', MqttQos.atLeastOnce);
        client.updates?.listen(_onMessage);
      }
    } catch (_) {}
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final msg in messages) {
      final raw = (msg.payload as MqttPublishMessage).payload.message;
      try {
        final list =
            (jsonDecode(utf8.decode(raw)) as List).cast<Map<String, dynamic>>();
        _lastState = list;

        // If a dismiss arrived while _lastState was empty (service restart
        // race), publish the MQTT reset now instead of processing normally.
        if (_dismissPending) {
          _dismissPending = false;
          _publishDismissReset();
          return;
        }

        for (final t in list) {
          _processTimer(t);
        }
      } catch (_) {}
    }
  }

  void _processTimer(Map<String, dynamic> t) {
    final id = t['id'] as String? ?? '';
    final name = t['name'] as String? ?? 'Timer';
    final wasElapsed = t['wasElapsed'] as bool? ?? false;
    final isRunning = t['isRunning'] as bool? ?? false;
    final prevElapsed = _wasElapsed[id] ?? false;

    // Remote alarm (another device published wasElapsed: true).
    if (wasElapsed && !prevElapsed && !_appInForeground) {
      _fireAlarm(name);
    }

    // Remote dismiss.
    if (!wasElapsed && prevElapsed && _alarmFiring) {
      _clearAlarm();
    }

    _wasElapsed[id] = wasElapsed;

    // Schedule / cancel the local countdown.
    _countdowns[id]?.cancel();
    _countdowns.remove(id);
    if (isRunning && !wasElapsed && !_appInForeground) {
      _scheduleCountdown(t);
    }
  }

  // ── Local countdown ───────────────────────────────────────────────────────

  void _scheduleCountdown(Map<String, dynamic> t) {
    final id = t['id'] as String? ?? '';
    final name = t['name'] as String? ?? 'Timer';
    final remainingMs = (t['remainingMs'] as num?)?.toInt();
    final lastTickStr = t['lastTickUtc'] as String?;

    if (remainingMs == null) return;

    var remaining = Duration(milliseconds: remainingMs);
    if (lastTickStr != null) {
      final lastTick = DateTime.tryParse(lastTickStr);
      if (lastTick != null) {
        remaining = remaining - DateTime.now().toUtc().difference(lastTick);
      }
    }

    if (remaining <= Duration.zero) {
      if (!_alarmFiring && !_appInForeground) _fireAndPublish(id, name);
      return;
    }

    _countdowns[id] = Timer(remaining, () {
      if (!_alarmFiring && !_appInForeground) _fireAndPublish(id, name);
    });
  }

  void _fireAndPublish(String timerId, String name) {
    _fireAlarm(name);

    // Publish wasElapsed: true to MQTT so other devices know.
    if (_lastState.isEmpty) return;
    final updated = _lastState.map((t) {
      if (t['id'] == timerId) {
        return <String, dynamic>{...t, 'wasElapsed': true, 'isRunning': false};
      }
      return t;
    }).toList();
    _publishState(updated);
    _wasElapsed[timerId] = true;
    _lastState = updated;
  }

  // ── Alarm ─────────────────────────────────────────────────────────────────

  void _fireAlarm(String name) async {
    if (_alarmFiring) return;
    _alarmFiring = true;

    // Show alarm notification and play sound via the native AlarmNotificationHelper.
    // The background engine listener passes playSound=true so the native side
    // plays the bundled WAV directly — no dependency on audioplayers working
    // in a secondary Flutter engine.
    try {
      await const MethodChannel('timer/notifications')
          .invokeMethod('showAlarm', {'name': name});
    } catch (_) {}
  }

  Future<void> _clearAlarm() async {
    if (!_alarmFiring) return;
    _alarmFiring = false;
    try {
      await const MethodChannel('timer/notifications').invokeMethod('cancelAlarm');
    } catch (_) {}
  }

  // Awaits cancelAlarm before notifying the main isolate so the native
  // mediaSession is fully released before showAlarm re-creates it.
  Future<void> _handoverAlarm(String? name) async {
    await _clearAlarm();
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      'event': 'handover_alarm',
      if (name != null) 'name': name,
    });
  }

  void _dismiss() {
    // Always clear if we were the ones playing; don't bail early — the alarm
    // may have been fired by the main isolate (foreground) in which case
    // _alarmFiring is false here, but we still need to publish the reset.
    if (_alarmFiring) _clearAlarm();

    if (_lastState.isNotEmpty) {
      _publishDismissReset();
    } else {
      // MQTT state not received yet (service restart race): defer the reset
      // until the next MQTT message arrives.
      _dismissPending = true;
    }

    FlutterForegroundTask.sendDataToMain(<String, dynamic>{'event': 'dismissed'});
  }

  void _publishDismissReset() {
    bool changed = false;
    final updated = _lastState.map((t) {
      if (t['wasElapsed'] as bool? ?? false) {
        changed = true;
        return <String, dynamic>{...t, 'wasElapsed': false};
      }
      return t;
    }).toList();
    if (changed) {
      _publishState(updated);
      for (final t in updated) {
        _wasElapsed[t['id'] as String? ?? ''] = false;
      }
      _lastState = updated;
    }
  }

  void _publishState(List<Map<String, dynamic>> state) {
    if (_client == null || _roomCode == null) return;
    final payload = jsonEncode(state);
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client!.publishMessage(
        'wt/$_roomCode/state', MqttQos.atLeastOnce, builder.payload!,
        retain: true);
  }
}
