import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'mqtt_service.dart';
import 'notification_service.dart';
import 'timer_model.dart';
import 'timer_widget.dart';

bool get isDesktop =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

Future<void> bringToFront() async {
  if (!isDesktop) return;
  await windowManager.setAlwaysOnTop(true);
  await windowManager.show();
  await windowManager.focus();
}

Future<void> releaseOnTop() async {
  if (!isDesktop) return;
  await windowManager.setAlwaysOnTop(false);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) await windowManager.ensureInitialized();

  final model = TimerModel();
  await model.load();

  final sound = SoundService();
  final mqtt = MqttService();
  final notifications = NotificationService();
  await notifications.init();

  model.setMqtt(mqtt);
  model.onRemoteAlarm = (timerId) {
    final name = model.timers.firstWhere((t) => t.id == timerId,
        orElse: () => model.timers.first).name;
    sound.play();
    bringToFront();
    notifications.showAlarm(name);
  };
  model.onRemoteDismiss = () {
    sound.stop();
    releaseOnTop();
    notifications.cancelAlarm();
  };

  notifications.onDismiss = () {
    sound.stop();
    releaseOnTop();
    model.dismissAllElapsed();
    notifications.cancelAlarm();
  };

  runApp(TimerApp(model: model, sound: sound, mqtt: mqtt, notifications: notifications));

  // Init MQTT after app is running (connects in background)
  await mqtt.initFromPrefs();
}

// ── App ────────────────────────────────────────────────────────────────────────

class TimerApp extends StatelessWidget {
  final TimerModel model;
  final SoundService sound;
  final MqttService mqtt;
  final NotificationService notifications;

  const TimerApp({super.key, required this.model, required this.sound, required this.mqtt, required this.notifications});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: model),
        ChangeNotifierProvider.value(value: sound),
        ChangeNotifierProvider.value(value: mqtt),
        Provider.value(value: notifications),
      ],
      child: MaterialApp(
        title: 'Timer',
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: const _HomePage(),
      ),
    );
  }

  ThemeData _theme() {
    const bg = Color(0xFF0D1117);
    const surface = Color(0xFF161B27);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.dark(
        primary: const Color(0xFF7C6FFF),
        surface: surface,
        onSurface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
        iconTheme: IconThemeData(color: Colors.white70),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: Colors.white70),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xFF1C2333),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
      ),
    );
  }
}

// ── Home page ──────────────────────────────────────────────────────────────────

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          // MQTT status dot
          Consumer<MqttService>(
            builder: (_, mqtt, __) {
              final color = switch (mqtt.status) {
                MqttStatus.connected => const Color(0xFF00C9A7),
                MqttStatus.connecting => Colors.amber,
                MqttStatus.disconnected => Colors.white24,
              };
              final tooltip = switch (mqtt.status) {
                MqttStatus.connected => 'Syncing — room: ${mqtt.roomCode}',
                MqttStatus.connecting => 'Connecting…',
                MqttStatus.disconnected => 'Sync off',
              };
              return Tooltip(
                message: tooltip,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                  ),
                ),
              );
            },
          ),
          // Stop sound
          Consumer2<SoundService, TimerModel>(
            builder: (_, sound, model, __) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: sound.isPlaying
                  ? IconButton(
                      key: const ValueKey('stop'),
                      tooltip: 'Stop sound',
                      icon: const Icon(Icons.volume_off_rounded, size: 24),
                      onPressed: () {
                        sound.stop();
                        model.dismissAllElapsed();
                      },
                    )
                  : const SizedBox.shrink(key: ValueKey('silent')),
            ),
          ),
          Consumer<TimerModel>(
            builder: (_, model, __) => IconButton(
              tooltip: 'Add timer',
              icon: const Icon(Icons.add_circle_outline_rounded, size: 26),
              onPressed: model.addTimer,
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: 24),
            onPressed: () => showDialog(
              context: context,
              builder: (ctx) => const _SettingsDialog(),
            ),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      body: Consumer<TimerModel>(
        builder: (_, model, __) => ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          itemCount: model.timers.length,
          itemBuilder: (_, i) => TimerWidget(
            key: ValueKey(model.timers[i].id),
            timerData: model.timers[i],
            accentColor: Color(model.timers[i].colorValue),
            onTimerUpdated: (t) => model.updateTimer(i, t),
            onRemove: model.timers.length > 1 ? () => model.removeTimer(i) : null,
          ),
        ),
      ),
    );
  }
}

// ── Settings dialog ────────────────────────────────────────────────────────────

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final _hostCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _roomCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _useWebSocket = false;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hostCtrl.text = prefs.getString('mqtt_host') ?? '';
      _userCtrl.text = prefs.getString('mqtt_user') ?? '';
      _passCtrl.text = prefs.getString('mqtt_pass') ?? '';
      _roomCtrl.text = prefs.getString('mqtt_room') ?? '';
      _useWebSocket   = prefs.getBool('mqtt_ws') ?? false;
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _roomCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final mqtt = context.read<MqttService>();
    setState(() { _connecting = true; _error = null; });
    final err = await mqtt.connect(
      host: _hostCtrl.text,
      username: _userCtrl.text,
      password: _passCtrl.text,
      roomCode: _roomCtrl.text,
      useWebSocket: _useWebSocket,
    );
    if (mounted) setState(() { _connecting = false; _error = err; });
  }

  Future<void> _disconnect() async {
    await context.read<MqttService>().disconnect();
    setState(() { _error = null; });
  }

  Widget _field(String label, TextEditingController ctrl, {bool obscure = false, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        obscureText: obscure && _obscurePass,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 13),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          suffixIcon: obscure
              ? IconButton(
                  icon: Icon(_obscurePass ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                  onPressed: () => setState(() => _obscurePass = !_obscurePass),
                )
              : null,
        ),
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sound = context.watch<SoundService>();
    final mqtt = context.watch<MqttService>();
    final connected = mqtt.connected;

    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Sound ──────────────────────────────
              const Text('SOUND', style: TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Alert sound', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  sound.currentSoundName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF7C6FFF), fontSize: 11),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(onPressed: sound.pickSound, child: const Text('Choose…')),
                    if (sound.customSoundPath != null)
                      IconButton(
                        tooltip: 'Reset to default',
                        icon: const Icon(Icons.restart_alt_rounded, size: 18),
                        onPressed: sound.resetSound,
                      ),
                  ],
                ),
              ),

              const Divider(height: 28, color: Colors.white12),

              // ── Sync ───────────────────────────────
              Row(
                children: [
                  const Text('SYNC', style: TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 1.5)),
                  const SizedBox(width: 8),
                  Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: connected ? const Color(0xFF00C9A7) : Colors.white24,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    connected ? 'Connected' : 'Disconnected',
                    style: TextStyle(
                      fontSize: 11,
                      color: connected ? const Color(0xFF00C9A7) : Colors.white38,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (!connected) ...[
                _field('HiveMQ host', _hostCtrl, hint: 'abc.s1.eu.hivemq.cloud'),
                _field('Username', _userCtrl),
                _field('Password', _passCtrl, obscure: true),
                _field('Room code', _roomCtrl, hint: 'same on all devices'),
                Row(
                  children: [
                    Switch(
                      value: _useWebSocket,
                      onChanged: (v) => setState(() => _useWebSocket = v),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Use WebSocket (port 8884)\ntry this if port 8883 is blocked',
                        style: TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _connecting ? null : _connect,
                    child: Text(_connecting ? 'Connecting…' : 'Connect'),
                  ),
                ),
              ] else ...[
                Text('Room: ${mqtt.roomCode}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _disconnect,
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white54),
                    child: const Text('Disconnect'),
                  ),
                ),
              ],

              const SizedBox(height: 8),
              const Text(
                'All devices sharing the same room code will sync in real time.',
                style: TextStyle(fontSize: 11, color: Colors.white24),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
