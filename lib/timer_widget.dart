import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import 'main.dart' show bringToFront, releaseOnTop;
import 'notification_service.dart';

import 'timer_model.dart';

class TimerWidget extends StatefulWidget {
  final TimerData timerData;
  final Color accentColor;
  final Function(TimerData) onTimerUpdated;
  final VoidCallback? onRemove;

  const TimerWidget({
    super.key,
    required this.timerData,
    required this.accentColor,
    required this.onTimerUpdated,
    this.onRemove,
  });

  @override
  State<TimerWidget> createState() => _TimerWidgetState();
}

class _TimerWidgetState extends State<TimerWidget> with SingleTickerProviderStateMixin {
  Timer? _ticker;
  late final Ticker _frameTicker;

  @override
  void initState() {
    super.initState();
    _frameTicker = createTicker((_) { if (mounted) setState(() {}); });
    if (widget.timerData.isRunning) {
      _startTicker();
      _frameTicker.start();
    }
  }

  @override
  void didUpdateWidget(TimerWidget old) {
    super.didUpdateWidget(old);
    if (widget.timerData.isRunning && !old.timerData.isRunning) {
      _startTicker();
      _frameTicker.start();
    } else if (!widget.timerData.isRunning && old.timerData.isRunning) {
      _ticker?.cancel();
      _frameTicker.stop();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _frameTicker.dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final data = widget.timerData;
      if (!data.isRunning) return;

      final now = DateTime.now();
      final elapsed = now.difference(data.lastTick ?? now);
      final newRemaining = data.remaining - elapsed;

      if (newRemaining <= Duration.zero) {
        _ticker?.cancel();
        widget.onTimerUpdated(data.copyWith(
          remaining: data.target, // auto-reset to full duration
          isRunning: false,
          wasElapsed: true,
          lastTick: now,
        ));
        _playFinishSound();
        HapticFeedback.heavyImpact();
      } else {
        widget.onTimerUpdated(data.copyWith(
          remaining: newRemaining,
          lastTick: now,
        ));
      }
    });
  }

  void _playFinishSound() {
    if (!mounted) return;
    context.read<SoundService>().play();
    bringToFront();
    context.read<NotificationService>().showAlarm(widget.timerData.name);
  }

  void _dismissElapsed() {
    context.read<SoundService>().stop();
    context.read<NotificationService>().cancelAlarm();
    _reset();
  }

  void _toggle() {
    HapticFeedback.lightImpact();
    final data = widget.timerData;
    if (data.isRunning) {
      widget.onTimerUpdated(data.stopped());
    } else if (data.hasTarget) {
      releaseOnTop();
      widget.onTimerUpdated(data.copyWith(
        isRunning: true,
        wasElapsed: false,
        lastTick: DateTime.now(),
      ));
    }
  }

  void _reset() {
    HapticFeedback.mediumImpact();
    _ticker?.cancel();
    releaseOnTop();
    widget.onTimerUpdated(widget.timerData.reset());
  }

  void _editName() {
    final ctrl = TextEditingController(text: widget.timerData.name);
    showDialog(
      context: context,
      builder: (ctx) => _NameDialog(
        controller: ctrl,
        initialColorValue: widget.timerData.colorValue,
        onSave: (name, colorValue) {
          widget.onTimerUpdated(widget.timerData.copyWith(name: name, colorValue: colorValue));
          Navigator.of(ctx).pop();
        },
        onCancel: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  void _setTime() {
    showDialog(
      context: context,
      builder: (ctx) => _DurationDialog(
        initial: widget.timerData.target,
        accentColor: widget.accentColor,
        onSave: (d) {
          widget.onTimerUpdated(widget.timerData.withTarget(d));
          Navigator.of(ctx).pop();
        },
        onCancel: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  Duration get _displayRemaining {
    final data = widget.timerData;
    if (!data.isRunning || data.lastTick == null) return data.remaining;
    final elapsed = DateTime.now().difference(data.lastTick!);
    final r = data.remaining - elapsed;
    return r < Duration.zero ? Duration.zero : r;
  }

  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  double get _ringProgress {
    final data = widget.timerData;
    if (!data.hasTarget) return 0.0;
    return _displayRemaining.inMilliseconds / data.target.inMilliseconds;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.timerData;
    final running = data.isRunning;
    final elapsed = data.wasElapsed;
    final color = elapsed ? Colors.amber.shade400 : widget.accentColor;

    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: elapsed ? const Color(0xFF251A08) : const Color(0xFF1C2333),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: running
              ? color.withValues(alpha: 0.45)
              : elapsed
                  ? Colors.amber.withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.06),
          width: running ? 1.5 : 1.0,
        ),
        boxShadow: running
            ? [BoxShadow(color: color.withValues(alpha: 0.12), blurRadius: 24, spreadRadius: 2)]
            : elapsed
                ? [BoxShadow(color: Colors.amber.withValues(alpha: 0.08), blurRadius: 16)]
                : const [],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                GestureDetector(
                  onTap: _editName,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        data.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: color,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Icon(Icons.edit_rounded, size: 13, color: color.withValues(alpha: 0.5)),
                    ],
                  ),
                ),
                const Spacer(),
                if (widget.onRemove != null)
                  GestureDetector(
                    onTap: widget.onRemove,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // Ring + time display
            GestureDetector(
              onTap: !running && !elapsed ? _setTime : null,
              child: SizedBox(
                width: 180,
                height: 180,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(180, 180),
                      painter: _RingPainter(
                        progress: _ringProgress,
                        color: color,
                        running: running,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 148,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              data.hasTarget ? _fmt(_displayRemaining) : '--:--:--',
                              style: TextStyle(
                                fontSize: 51,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                                color: running
                                    ? Colors.white
                                    : elapsed
                                        ? Colors.amber.shade300
                                        : Colors.white60,
                                letterSpacing: 3,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _StatusBadge(
                          running: running,
                          wasElapsed: elapsed,
                          hasTarget: data.hasTarget,
                          remaining: data.remaining,
                          lastTick: data.lastTick,
                          color: color,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 22),

            // Buttons
            Row(
              children: [
                Expanded(
                  flex: 5,
                  child: _FilledButton(
                    onPressed: !data.hasTarget ? _setTime : _toggle,
                    icon: !data.hasTarget
                        ? Icons.timer_outlined
                        : running
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                    label: !data.hasTarget
                        ? 'Set Time'
                        : running
                            ? 'Pause'
                            : 'Start',
                    color: color,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: _OutlineButton(
                    onPressed: _reset,
                    icon: Icons.replay_rounded,
                    label: 'Reset',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (elapsed) {
      return Stack(
        children: [
          card,
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismissElapsed,
            ),
          ),
        ],
      );
    }
    return card;
  }
}

// ── Status badge ───────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final bool running;
  final bool wasElapsed;
  final bool hasTarget;
  final Duration remaining;
  final DateTime? lastTick;
  final Color color;
  const _StatusBadge({
    required this.running,
    required this.wasElapsed,
    required this.hasTarget,
    required this.remaining,
    required this.lastTick,
    required this.color,
  });

  String _endTime() {
    // lastTick + remaining is constant each tick (they cancel out)
    final end = lastTick != null
        ? lastTick!.add(remaining)
        : DateTime.now().add(remaining);
    final h = end.hour.toString().padLeft(2, '0');
    final m = end.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    if (wasElapsed) {
      return Text('ELAPSED',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
              color: Colors.amber.shade300, letterSpacing: 2));
    }
    if (!hasTarget) {
      return Text('TAP TO SET',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.25), letterSpacing: 2));
    }
    if (!running) {
      return Text('PAUSED',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.25), letterSpacing: 2));
    }
    return Text(_endTime(),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600,
            color: Colors.white, letterSpacing: 1));
  }
}

// ── Buttons ────────────────────────────────────────────────────────────────────

class _FilledButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final Color color;

  const _FilledButton({
    required this.onPressed, required this.icon,
    required this.label, required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color, foregroundColor: Colors.white,
        elevation: 0, padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  const _OutlineButton({required this.onPressed, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white54,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Name dialog ────────────────────────────────────────────────────────────────

class _NameDialog extends StatefulWidget {
  final TextEditingController controller;
  final int initialColorValue;
  final Function(String, int) onSave;
  final VoidCallback onCancel;

  const _NameDialog({
    required this.controller,
    required this.initialColorValue,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(widget.initialColorValue));
  }

  void _submit() {
    final v = widget.controller.text.trim();
    widget.onSave(v.isEmpty ? 'Timer' : v, _hsv.toColor().value);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _hsv.toColor();
    return AlertDialog(
      backgroundColor: const Color(0xFF1C2333),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.hardEdge,
      title: const Text('Rename Timer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Enter a name',
              hintStyle: const TextStyle(color: Colors.white24),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: accent, width: 2)),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          // SB area
          ClipRect(
            child: SizedBox(
              width: 260,
              height: 180,
              child: ColorPickerArea(
                _hsv,
                (h) => setState(() => _hsv = h),
                PaletteType.hsv,
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Hue bar
          ClipRect(
            child: SizedBox(
              width: 260,
              height: 22,
              child: ColorPickerSlider(
                TrackType.hue,
                _hsv,
                (h) => setState(() => _hsv = h),
                displayThumbColor: true,
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Preview swatch
          Container(
            height: 28,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        TextButton(
          onPressed: _submit,
          style: TextButton.styleFrom(foregroundColor: accent),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ── Duration dialog (text input) ───────────────────────────────────────────────

class _DurationDialog extends StatefulWidget {
  final Duration initial;
  final Color accentColor;
  final Function(Duration) onSave;
  final VoidCallback onCancel;

  const _DurationDialog({
    required this.initial, required this.accentColor,
    required this.onSave, required this.onCancel,
  });

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog> {
  late final TextEditingController _hCtrl;
  late final TextEditingController _mCtrl;
  late final TextEditingController _sCtrl;
  String? _error;
  final _dragAccum = <TextEditingController, double>{};

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _hCtrl = TextEditingController(text: d.inHours.toString().padLeft(2, '0'));
    _mCtrl = TextEditingController(text: (d.inMinutes % 60).toString().padLeft(2, '0'));
    _sCtrl = TextEditingController(text: (d.inSeconds % 60).toString().padLeft(2, '0'));
    // Select all in the autofocused (minutes) field on first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _mCtrl.text.length);
    });
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _mCtrl.dispose();
    _sCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final h = int.tryParse(_hCtrl.text) ?? 0;
    final m = int.tryParse(_mCtrl.text) ?? 0; // total minutes, converted automatically
    final s = int.tryParse(_sCtrl.text) ?? 0;
    if (s >= 60) {
      setState(() => _error = 'Seconds must be 0–59');
      return;
    }
    final totalSeconds = h * 3600 + m * 60 + s;
    if (totalSeconds == 0) {
      setState(() => _error = 'Duration must be greater than zero');
      return;
    }
    widget.onSave(Duration(seconds: totalSeconds));
  }

  void _adjust(TextEditingController ctrl, int delta, {int min = 0, int? max}) {
    final current = int.tryParse(ctrl.text) ?? 0;
    var next = current + delta;
    if (next < min) next = min;
    if (max != null && next > max) next = max;
    ctrl.text = next.toString().padLeft(2, '0');
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    setState(() => _error = null);
  }

  void _scroll(TextEditingController ctrl, PointerScrollEvent e, {int min = 0, int? max}) {
    _adjust(ctrl, e.scrollDelta.dy > 0 ? -1 : 1, min: min, max: max);
  }

  void _drag(TextEditingController ctrl, DragUpdateDetails d, {int min = 0, int? max}) {
    _dragAccum[ctrl] = (_dragAccum[ctrl] ?? 0) + d.delta.dy;
    while ((_dragAccum[ctrl] ?? 0) > 18) {
      _dragAccum[ctrl] = (_dragAccum[ctrl] ?? 0) - 18;
      _adjust(ctrl, -1, min: min, max: max);
    }
    while ((_dragAccum[ctrl] ?? 0) < -18) {
      _dragAccum[ctrl] = (_dragAccum[ctrl] ?? 0) + 18;
      _adjust(ctrl, 1, min: min, max: max);
    }
  }

  Widget _field(TextEditingController ctrl, String label, {bool autofocus = false, int maxLength = 2, int min = 0, int? max}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onVerticalDragUpdate: (d) => _drag(ctrl, d, min: min, max: max),
          onVerticalDragStart: (_) => _dragAccum[ctrl] = 0,
          child: Listener(
          onPointerSignal: (e) { if (e is PointerScrollEvent) _scroll(ctrl, e, min: min, max: max); },
          child: SizedBox(
            width: maxLength > 2 ? 88 : 64,
            child: TextField(
              controller: ctrl,
              autofocus: autofocus,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: maxLength,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onTap: () => ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: Colors.white,
              ),
              decoration: InputDecoration(
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: widget.accentColor, width: 2),
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.35),
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C2333),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Set Duration'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _field(_hCtrl, 'HH', min: 0),
              Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: Text(':',
                    style: TextStyle(fontSize: 30,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.25),
                        fontFamily: 'monospace')),
              ),
              _field(_mCtrl, 'MM', autofocus: true, maxLength: 3, min: 0, max: 240),
              Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: Text(':',
                    style: TextStyle(fontSize: 30,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.25),
                        fontFamily: 'monospace')),
              ),
              _field(_sCtrl, 'SS', min: 0, max: 59),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        TextButton(
          onPressed: _save,
          style: TextButton.styleFrom(foregroundColor: widget.accentColor),
          child: const Text('Set'),
        ),
      ],
    );
  }
}

// ── Ring painter ───────────────────────────────────────────────────────────────

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool running;

  const _RingPainter({required this.progress, required this.color, required this.running});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    const sw = 6.0;
    const startAngle = -math.pi / 2;

    canvas.drawCircle(center, radius,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.07)
          ..strokeWidth = sw
          ..style = PaintingStyle.stroke);

    if (progress <= 0) return;

    final sweepAngle = 2 * math.pi * progress;
    final arcRect = Rect.fromCircle(center: center, radius: radius);

    if (running) {
      canvas.drawArc(arcRect, startAngle, sweepAngle, false,
          Paint()
            ..color = color.withValues(alpha: 0.25)
            ..strokeWidth = sw + 8
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }

    canvas.drawArc(arcRect, startAngle, sweepAngle, false,
        Paint()
          ..color = running ? color : color.withValues(alpha: 0.45)
          ..strokeWidth = sw
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);

  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.running != running || old.color != color;
}
