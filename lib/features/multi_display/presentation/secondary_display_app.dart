import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../domain/dual_display_session.dart';

const _publicChannel = MethodChannel(
  'com.ersingundem.larenor/dual_display_public',
);

void runSecondaryDisplayApp(List<String> arguments) {
  String? routeId;
  PublicCoreStatusSnapshot? snapshot;
  try {
    if (arguments.length == 2 && arguments.first == 'core.status') {
      routeId = arguments.first;
      snapshot = PublicCoreStatusSnapshot.fromPublicMessage(
        jsonDecode(arguments[1]),
      );
    }
  } on Object {
    routeId = null;
    snapshot = null;
  }
  runApp(SecondaryDisplayApp(routeId: routeId, initialSnapshot: snapshot));
}

/// A public external-display surface with no primary-engine session state.
class SecondaryDisplayApp extends StatelessWidget {
  const SecondaryDisplayApp({
    super.key,
    required this.routeId,
    required this.initialSnapshot,
    this.channel = _publicChannel,
    this.now = DateTime.now,
  });

  final String? routeId;
  final PublicCoreStatusSnapshot? initialSnapshot;
  final MethodChannel channel;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) => CupertinoApp(
    debugShowCheckedModeBanner: false,
    theme: const CupertinoThemeData(
      brightness: Brightness.dark,
      primaryColor: Color(0xFF7DC4FF),
      scaffoldBackgroundColor: Color(0xFF09121F),
    ),
    home: _SecondaryDisplaySurface(
      routeId: routeId,
      initialSnapshot: initialSnapshot,
      channel: channel,
      now: now,
    ),
  );
}

class _SecondaryDisplaySurface extends StatefulWidget {
  const _SecondaryDisplaySurface({
    required this.routeId,
    required this.initialSnapshot,
    required this.channel,
    required this.now,
  });

  final String? routeId;
  final PublicCoreStatusSnapshot? initialSnapshot;
  final MethodChannel channel;
  final DateTime Function() now;

  @override
  State<_SecondaryDisplaySurface> createState() =>
      _SecondaryDisplaySurfaceState();
}

class _SecondaryDisplaySurfaceState extends State<_SecondaryDisplaySurface> {
  Timer? _expiry;
  PublicCoreStatusSnapshot? _snapshot;
  DateTime? _localExpiry;

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler(_onNativeCall);
    _accept(widget.initialSnapshot);
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) => _expire());
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'publicSnapshot' || widget.routeId != 'core.status') {
      throw MissingPluginException();
    }
    final candidate = PublicCoreStatusSnapshot.fromPublicMessage(
      call.arguments,
    );
    final current = _snapshot;
    if (current != null &&
        candidate.snapshotRevision < current.snapshotRevision) {
      throw PlatformException(code: 'staleSnapshot');
    }
    if (current == null ||
        candidate.snapshotRevision > current.snapshotRevision) {
      setState(() => _accept(candidate));
    }
    return true;
  }

  void _accept(PublicCoreStatusSnapshot? snapshot) {
    _snapshot = snapshot;
    _localExpiry = snapshot == null
        ? null
        : widget.now().add(
            Duration(
              milliseconds: snapshot.expiresAtMs - snapshot.observedAtMs,
            ),
          );
  }

  void _expire() {
    final expiry = _localExpiry;
    if (!mounted || expiry == null || widget.now().isBefore(expiry)) return;
    setState(() => _accept(null));
  }

  @override
  void dispose() {
    _expiry?.cancel();
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final turkish = Localizations.localeOf(context).languageCode == 'tr';
    final validRoute = widget.routeId == 'core.status';
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: validRoute
                  ? _CoreStatusSurface(snapshot: _snapshot, turkish: turkish)
                  : _UnavailableSurface(turkish: turkish),
            ),
          ),
        ),
      ),
    );
  }
}

class _CoreStatusSurface extends StatelessWidget {
  const _CoreStatusSurface({required this.snapshot, required this.turkish});

  final PublicCoreStatusSnapshot? snapshot;
  final bool turkish;

  @override
  Widget build(BuildContext context) {
    final value = snapshot;
    if (value == null) {
      return _UnavailableSurface(turkish: turkish, stale: true);
    }
    final diskPercent =
        ((value.dataDiskTotalBytes - value.dataDiskFreeBytes) *
                100 /
                value.dataDiskTotalBytes)
            .round();
    return Semantics(
      container: true,
      liveRegion: true,
      label: turkish ? 'Genel Core durumu' : 'Public Core status',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(CupertinoIcons.checkmark_shield_fill, size: 72),
          const SizedBox(height: 24),
          Text(
            turkish ? 'Core çevrimiçi' : 'Core online',
            key: const ValueKey('secondary-core-online'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 32),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            runSpacing: 16,
            children: [
              _Metric(
                label: turkish ? 'Sistem yükü' : 'System load',
                value: '${value.systemLoadPercent}%',
              ),
              _Metric(
                label: turkish ? 'Core belleği' : 'Core memory',
                value: '${value.processMemoryMiB} MiB',
              ),
              _Metric(
                label: turkish ? 'Veri diski kullanımı' : 'Data disk used',
                value: '$diskPercent%',
              ),
              _Metric(
                label: turkish ? 'İşlem çalışma süresi' : 'Process uptime',
                value: _uptime(value.processUptimeSeconds),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _uptime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return '${hours}h ${minutes}m';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    width: 210,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFF14243A),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        Text(label, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          value,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _UnavailableSurface extends StatelessWidget {
  const _UnavailableSurface({required this.turkish, this.stale = false});

  final bool turkish;
  final bool stale;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(CupertinoIcons.exclamationmark_shield_fill, size: 72),
        const SizedBox(height: 24),
        Text(
          stale
              ? turkish
                    ? 'Core durumu güncel değil'
                    : 'Core status is stale'
              : turkish
              ? 'Harici görev kullanılamıyor'
              : 'External task unavailable',
          key: ValueKey(
            stale ? 'secondary-core-stale' : 'secondary-unavailable',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}
