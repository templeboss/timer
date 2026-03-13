import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
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
  final _player = AudioPlayer();
  String? _soundPath;
  String? _roomCode;
  bool _alarmFiring = false;
  // True until the main isolate tells us the app went to background.
  // Prevents re-triggering alarms that already fired while in the foreground.
  bool _appInForeground = true;
  List<Map<String, dynamic>> _lastState = [];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _prepareSound();

    final prefs = await SharedPreferences.getInstance();
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
    await _player.stop();
    _player.dispose();
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
        _clearAlarm();
        FlutterForegroundTask.sendDataToMain(<String, dynamic>{
          'event': 'handover_alarm',
          if (name != null) 'name': name,
        });
      }
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
      if (!_alarmFiring) _fireAndPublish(id, name);
      return;
    }

    _countdowns[id] = Timer(remaining, () {
      if (!_alarmFiring) _fireAndPublish(id, name);
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

    // Show the alarm notification through the same AlarmNotificationHelper
    // used in the foreground — works because TimerBackgroundEngineListener
    // registers timer/notifications on this engine too.
    try {
      await const MethodChannel('timer/notifications')
          .invokeMethod('showAlarm', {'name': name});
    } catch (_) {}

    final path = _soundPath;
    if (path != null) {
      await _player.stop();
      await _player.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: false,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ));
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(DeviceFileSource(path));
    }
  }

  void _clearAlarm() async {
    if (!_alarmFiring) return;
    _alarmFiring = false;
    await _player.stop();
    try {
      await const MethodChannel('timer/notifications').invokeMethod('cancelAlarm');
    } catch (_) {}
  }

  void _dismiss() {
    if (!_alarmFiring) return;
    _clearAlarm();

    // Publish wasElapsed: false for all elapsed timers.
    if (_lastState.isNotEmpty) {
      final updated = _lastState.map((t) {
        if (t['wasElapsed'] as bool? ?? false) {
          return <String, dynamic>{...t, 'wasElapsed': false};
        }
        return t;
      }).toList();
      _publishState(updated);
      for (final t in updated) {
        final id = t['id'] as String? ?? '';
        _wasElapsed[id] = false;
      }
      _lastState = updated;
    }

    FlutterForegroundTask.sendDataToMain(<String, dynamic>{'event': 'dismissed'});
  }

  void _publishState(List<Map<String, dynamic>> state) {
    if (_client == null || _roomCode == null) return;
    final payload = jsonEncode(state);
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client!.publishMessage(
        'wt/$_roomCode/state', MqttQos.atLeastOnce, builder.payload!,
        retain: true);
  }

  // ── Sound asset ───────────────────────────────────────────────────────────

  Future<void> _prepareSound() async {
    try {
      final data = await rootBundle.load('default.wav');
      final bytes = data.buffer.asUint8List();
      final tmp =
          File('${Directory.systemTemp.path}/work_timer_alarm_bg.wav');
      await tmp.writeAsBytes(bytes, flush: true);
      _soundPath = tmp.path;
    } catch (_) {}
  }
}
