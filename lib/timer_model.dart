import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mqtt_service.dart';

// ── Palette ───────────────────────────────────────────────────────────────────

const kTimerPalette = [
  0xFF7C6FFF, // violet
  0xFF00C9A7, // teal
  0xFFFF6B6B, // coral
  0xFFFFD166, // amber
  0xFF4FC3F7, // sky
  0xFFFF9F43, // orange
  0xFFA29BFE, // lavender
  0xFF55EFC4, // mint
  0xFFE84393, // pink
  0xFF74B9FF, // blue
  0xFFB2BEC3, // silver
  0xFFFF7675, // salmon
];

// ── TimerData ─────────────────────────────────────────────────────────────────

class TimerData {
  final String id;
  final String name;
  final int colorValue;
  final Duration target;
  final Duration remaining;
  final bool isRunning;
  final bool wasElapsed;
  final DateTime? lastTick;

  const TimerData({
    required this.id,
    this.name = 'Timer',
    this.colorValue = 0xFF7C6FFF,
    this.target = Duration.zero,
    this.remaining = Duration.zero,
    this.isRunning = false,
    this.wasElapsed = false,
    this.lastTick,
  });

  bool get hasTarget => target > Duration.zero;

  // Persisted locally (config only)
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorValue': colorValue,
        'targetSeconds': target.inSeconds,
      };

  factory TimerData.fromJson(Map<String, dynamic> json) {
    final target = Duration(seconds: (json['targetSeconds'] as num?)?.toInt() ?? 0);
    return TimerData(
      id: json['id'] as String? ?? 'timer_1',
      name: json['name'] as String? ?? 'Timer',
      colorValue: (json['colorValue'] as num?)?.toInt() ?? kTimerPalette[0],
      target: target,
      remaining: target,
    );
  }

  // Full runtime state — used for MQTT sync
  Map<String, dynamic> toSyncJson() => {
        ...toJson(),
        'isRunning': isRunning,
        'wasElapsed': wasElapsed,
        'remainingMs': remaining.inMilliseconds,
        'lastTickUtc': lastTick?.toUtc().toIso8601String(),
      };

  factory TimerData.fromSyncJson(Map<String, dynamic> json) {
    final base = TimerData.fromJson(json);
    final remainingMs = (json['remainingMs'] as num?)?.toInt();
    final lastTickStr = json['lastTickUtc'] as String?;
    return base.copyWith(
      isRunning: json['isRunning'] as bool? ?? false,
      wasElapsed: json['wasElapsed'] as bool? ?? false,
      remaining: remainingMs != null ? Duration(milliseconds: remainingMs) : base.target,
      lastTick: lastTickStr != null ? DateTime.parse(lastTickStr).toLocal() : null,
    );
  }

  TimerData copyWith({
    String? id,
    String? name,
    int? colorValue,
    Duration? target,
    Duration? remaining,
    bool? isRunning,
    bool? wasElapsed,
    DateTime? lastTick,
  }) {
    return TimerData(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      target: target ?? this.target,
      remaining: remaining ?? this.remaining,
      isRunning: isRunning ?? this.isRunning,
      wasElapsed: wasElapsed ?? this.wasElapsed,
      lastTick: lastTick ?? this.lastTick,
    );
  }

  TimerData reset() => TimerData(
        id: id,
        name: name,
        colorValue: colorValue,
        target: target,
        remaining: target,
        isRunning: false,
        wasElapsed: false,
      );

  TimerData withTarget(Duration newTarget) => TimerData(
        id: id,
        name: name,
        colorValue: colorValue,
        target: newTarget,
        remaining: newTarget,
        isRunning: false,
        wasElapsed: false,
      );

  TimerData stopped() => TimerData(
        id: id,
        name: name,
        colorValue: colorValue,
        target: target,
        remaining: remaining,
        isRunning: false,
        wasElapsed: wasElapsed,
      );
}

// ── SoundService ──────────────────────────────────────────────────────────────

class SoundService extends ChangeNotifier {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  String? _tempPath;
  String? _customSoundPath;

  bool get isPlaying => _isPlaying;
  String? get customSoundPath => _customSoundPath;
  String get currentSoundName =>
      _customSoundPath != null ? File(_customSoundPath!).uri.pathSegments.last : 'default.wav';

  SoundService() {
    _prepareAsset();
  }

  Future<void> _prepareAsset() async {
    try {
      final data = await rootBundle.load('default.wav');
      final bytes = data.buffer.asUint8List();
      final tmp = File('${Directory.systemTemp.path}/work_timer_alarm.wav');
      await tmp.writeAsBytes(bytes, flush: true);
      _tempPath = tmp.path;
    } catch (_) {}
  }

  Future<void> play() async {
    final path = _customSoundPath ?? _tempPath;
    if (path == null) return;
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.loop);
    _isPlaying = true;
    notifyListeners();
    await _player.play(DeviceFileSource(path));
  }

  Future<void> pickSound() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'ogg', 'aac', 'm4a'],
      dialogTitle: 'Choose alert sound',
    );
    final path = result?.files.single.path;
    if (path != null) {
      _customSoundPath = path;
      notifyListeners();
    }
  }

  void resetSound() {
    _customSoundPath = null;
    notifyListeners();
  }

  Future<void> stop() async {
    await _player.stop();
    if (_isPlaying) {
      _isPlaying = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

// ── TimerModel ────────────────────────────────────────────────────────────────

class TimerModel extends ChangeNotifier {
  int _counter = 1;
  final List<TimerData> _timers = [
    TimerData(id: 'timer_1', name: 'Timer 1', target: const Duration(minutes: 5), remaining: const Duration(minutes: 5)),
  ];

  MqttService? _mqtt;
  bool _applyingRemote = false;

  /// Called when a remote device triggers an alarm.
  void Function(String timerId)? onRemoteAlarm;
  /// Called when a remote device dismisses an alarm.
  void Function()? onRemoteDismiss;

  List<TimerData> get timers => List.unmodifiable(_timers);

  void setMqtt(MqttService mqtt) {
    _mqtt = mqtt;
    mqtt.onStateReceived = applyRemoteState;
    mqtt.onReconnected = () => mqtt.publishState(_timers);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('timers');
    if (jsonStr == null) return;
    final list = jsonDecode(jsonStr) as List;
    if (list.isEmpty) return;
    _timers
      ..clear()
      ..addAll(list.map((e) => TimerData.fromJson(e as Map<String, dynamic>)));
    _counter = _timers.fold(0, (max, t) {
      final n = int.tryParse(t.id.replaceFirst('timer_', '')) ?? 0;
      return n > max ? n : max;
    });
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('timers', jsonEncode(_timers.map((t) => t.toJson()).toList()));
  }

  bool _isSyncWorthy(TimerData old, TimerData updated) =>
      old.isRunning != updated.isRunning ||
      old.wasElapsed != updated.wasElapsed ||
      old.name != updated.name ||
      old.colorValue != updated.colorValue ||
      old.target != updated.target;

  /// Resets wasElapsed on all elapsed timers and publishes — called by stop-sound button.
  void dismissAllElapsed() {
    bool any = false;
    for (int i = 0; i < _timers.length; i++) {
      if (_timers[i].wasElapsed) {
        _timers[i] = _timers[i].reset();
        any = true;
      }
    }
    if (any) {
      notifyListeners();
      _save();
      _mqtt?.publishState(_timers);
    }
  }

  void updateTimer(int index, TimerData updated) {
    final old = _timers[index];
    _timers[index] = updated;
    notifyListeners();
    _save();
    if (!_applyingRemote && _isSyncWorthy(old, updated)) {
      _mqtt?.publishState(_timers);
    }
  }

  void addTimer() {
    _counter++;
    _timers.add(TimerData(
      id: 'timer_$_counter',
      name: 'Timer $_counter',
      colorValue: kTimerPalette[(_counter - 1) % kTimerPalette.length],
      target: const Duration(minutes: 5),
      remaining: const Duration(minutes: 5),
    ));
    notifyListeners();
    _save();
    _mqtt?.publishState(_timers);
  }

  void removeTimer(int index) {
    if (_timers.length > 1) {
      _timers.removeAt(index);
      notifyListeners();
      _save();
      _mqtt?.publishState(_timers);
    }
  }

  /// Applies state received from a remote device via MQTT.
  void applyRemoteState(List<Map<String, dynamic>> list) {
    _applyingRemote = true;
    final incoming = list.map(TimerData.fromSyncJson).toList();

    // Detect alarm transitions
    for (final remote in incoming) {
      final localIdx = _timers.indexWhere((t) => t.id == remote.id);
      if (localIdx >= 0) {
        final local = _timers[localIdx];
        if (remote.wasElapsed && !local.wasElapsed) onRemoteAlarm?.call(remote.id);
        if (!remote.wasElapsed && local.wasElapsed) onRemoteDismiss?.call();
      }
    }

    _timers
      ..clear()
      ..addAll(incoming);
    _counter = _timers.fold(0, (max, t) {
      final n = int.tryParse(t.id.replaceFirst('timer_', '')) ?? 0;
      return n > max ? n : max;
    });

    _applyingRemote = false;
    notifyListeners();
    _save();
  }
}
