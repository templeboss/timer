import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'timer_model.dart';

enum MqttStatus { disconnected, connecting, connected }

class MqttService extends ChangeNotifier {
  MqttServerClient? _client;
  MqttStatus _status = MqttStatus.disconnected;
  String _roomCode = '';
  String _lastError = '';

  MqttStatus get status => _status;
  bool get connected => _status == MqttStatus.connected;
  String get roomCode => _roomCode;
  String get lastError => _lastError;

  void Function(List<Map<String, dynamic>>)? onStateReceived;
  void Function()? onReconnected;

  Future<void> initFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('mqtt_host') ?? '';
    final user = prefs.getString('mqtt_user') ?? '';
    final pass = prefs.getString('mqtt_pass') ?? '';
    final room = prefs.getString('mqtt_room') ?? '';
    final ws   = prefs.getBool('mqtt_ws') ?? false;
    if (host.isNotEmpty && user.isNotEmpty && room.isNotEmpty) {
      await connect(host: host, username: user, password: pass, roomCode: room, useWebSocket: ws);
    }
  }

  /// Returns null on success, human-readable error string on failure.
  Future<String?> connect({
    required String host,
    required String username,
    required String password,
    required String roomCode,
    bool useWebSocket = false,
  }) async {
    if (_status == MqttStatus.connecting) return null;
    await _doDisconnect();

    // Strip any protocol prefix the user may have pasted
    final cleanHost = host.trim()
        .replaceFirst(RegExp(r'^mqtts?://'), '')
        .replaceFirst(RegExp(r'^wss?://'), '')
        .replaceFirst(RegExp(r'/$'), '');

    _status = MqttStatus.connecting;
    _lastError = '';
    _roomCode = roomCode.trim();
    notifyListeners();

    final port = useWebSocket ? 8884 : 8883;
    final clientId = 'wt_${DateTime.now().millisecondsSinceEpoch}';
    final client = MqttServerClient.withPort(cleanHost, clientId, port);
    client.secure = true;
    client.useWebSocket = useWebSocket;
    client.keepAlivePeriod = 30;
    client.connectTimeoutPeriod = 10000;
    client.autoReconnect = true;
    client.logging(on: false);
    client.onDisconnected = _onDisconnected;
    client.onConnected = _onConnected;
    client.onAutoReconnected = _onAutoReconnected;
    // Accept valid certs; log bad-cert details instead of crashing silently
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(username, password)
        .startClean();

    try {
      final result = await client.connect();
      if (result?.state != MqttConnectionState.connected) {
        // Unauthorised (bad credentials) returns faulted state
        final state = result?.state;
        final err = state == MqttConnectionState.faulted
            ? 'Rejected — check username/password and that credentials exist in HiveMQ Access Management'
            : 'Connection failed (state: $state)';
        _status = MqttStatus.disconnected;
        _lastError = err;
        notifyListeners();
        return err;
      }
    } on SocketException catch (e) {
      final hint = useWebSocket
          ? 'WebSocket port 8884 blocked — check firewall'
          : 'Port 8883 may be blocked — try enabling "Use WebSocket" in settings';
      final err = 'Cannot reach broker: ${e.message}. $hint';
      _status = MqttStatus.disconnected;
      _lastError = err;
      notifyListeners();
      return err;
    } on HandshakeException catch (e) {
      final err = 'TLS handshake failed: ${e.message} — host may be wrong';
      _status = MqttStatus.disconnected;
      _lastError = err;
      notifyListeners();
      return err;
    } catch (e) {
      _status = MqttStatus.disconnected;
      _lastError = e.toString();
      notifyListeners();
      return e.toString();
    }

    _client = client;
    client.subscribe(_topic, MqttQos.atLeastOnce);
    client.updates?.listen(_onMessage);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mqtt_host', cleanHost);
    await prefs.setString('mqtt_user', username);
    await prefs.setString('mqtt_pass', password);
    await prefs.setString('mqtt_room', roomCode.trim());
    await prefs.setBool('mqtt_ws', useWebSocket);

    return null;
  }

  String get _topic => 'wt/$_roomCode/state';

  void publishState(List<TimerData> timers) {
    if (!connected || _client == null) return;
    final payload = jsonEncode(timers.map((t) => t.toSyncJson()).toList());
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client!.publishMessage(_topic, MqttQos.atLeastOnce, builder.payload!, retain: true);
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final msg in messages) {
      if (msg.topic != _topic) continue;
      final raw = (msg.payload as MqttPublishMessage).payload.message;
      try {
        final list = (jsonDecode(utf8.decode(raw)) as List).cast<Map<String, dynamic>>();
        onStateReceived?.call(list);
      } catch (_) {}
    }
  }

  void _onConnected() {
    _status = MqttStatus.connected;
    notifyListeners();
  }

  void _onAutoReconnected() {
    _status = MqttStatus.connected;
    notifyListeners();
    // Re-subscribe (autoReconnect doesn't restore subscriptions)
    _client?.subscribe(_topic, MqttQos.atLeastOnce);
    // Push local state so the other device stays in sync
    onReconnected?.call();
  }

  void _onDisconnected() {
    _status = MqttStatus.disconnected;
    notifyListeners();
  }

  Future<void> _doDisconnect() async {
    try { _client?.disconnect(); } catch (_) {}
    _client = null;
    _status = MqttStatus.disconnected;
    _roomCode = '';
  }

  Future<void> disconnect() async {
    await _doDisconnect();
    final prefs = await SharedPreferences.getInstance();
    for (final k in ['mqtt_host', 'mqtt_user', 'mqtt_pass', 'mqtt_room', 'mqtt_ws']) {
      await prefs.remove(k);
    }
    notifyListeners();
  }
}
