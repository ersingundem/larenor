import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../providers/settings_providers.dart';

/// Wraps the whole app; after [IdleModeSettings.timeoutMinutes] of no touch
/// input it swaps the dashboard for a low-distraction clock screen (also
/// reduces burn-in risk on an always-on wall panel). Any touch dismisses it.
class IdleGate extends ConsumerStatefulWidget {
  const IdleGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IdleGate> createState() => _IdleGateState();
}

class _IdleGateState extends ConsumerState<IdleGate> {
  Timer? _timer;
  bool _idle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetTimer());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    _timer?.cancel();
    if (_idle) setState(() => _idle = false);

    final settings = ref.read(idleModeProvider).value;
    if (settings == null || !settings.enabled) return;

    _timer = Timer(Duration(minutes: settings.timeoutMinutes), () {
      if (mounted) setState(() => _idle = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(idleModeProvider, (_, _) => _resetTimer());

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetTimer(),
      child: Stack(
        children: [
          widget.child,
          if (_idle) const Positioned.fill(child: _IdleClockScreen()),
        ],
      ),
    );
  }
}

class _IdleClockScreen extends ConsumerStatefulWidget {
  const _IdleClockScreen();

  @override
  ConsumerState<_IdleClockScreen> createState() => _IdleClockScreenState();
}

class _IdleClockScreenState extends ConsumerState<_IdleClockScreen> {
  late DateTime _now = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  Widget build(BuildContext context) {
    final entities = ref.watch(entitiesProvider).value;
    HaEntity? weather;
    if (entities != null) {
      for (final entity in entities.values) {
        if (entity.domain == 'weather') {
          weather = entity;
          break;
        }
      }
    }

    final time =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final date =
        '${_weekdays[_now.weekday - 1]}, ${_months[_now.month - 1]} ${_now.day}';

    return ColoredBox(
      color: CupertinoColors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              time,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 72,
                fontWeight: FontWeight.w200,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              date,
              style: const TextStyle(
                color: CupertinoColors.systemGrey,
                fontSize: 18,
              ),
            ),
            if (weather != null) ...[
              const SizedBox(height: 24),
              Text(
                '${weather.attributes['temperature']}° · ${weather.state}',
                style: const TextStyle(
                  color: CupertinoColors.systemGrey2,
                  fontSize: 16,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
