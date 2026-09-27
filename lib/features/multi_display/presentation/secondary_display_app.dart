import 'dart:async';

import 'package:flutter/cupertino.dart';

const _allowedRoutes = {'dashboard.overview', 'media.now-playing'};

void runSecondaryDisplayApp(List<String> arguments) {
  final routeId = arguments.length == 1 && _allowedRoutes.contains(arguments[0])
      ? arguments.single
      : null;
  runApp(SecondaryDisplayApp(routeId: routeId));
}

/// A public external-display surface with no primary-engine session state.
class SecondaryDisplayApp extends StatelessWidget {
  const SecondaryDisplayApp({super.key, required this.routeId});

  final String? routeId;

  @override
  Widget build(BuildContext context) => CupertinoApp(
    debugShowCheckedModeBanner: false,
    theme: const CupertinoThemeData(
      brightness: Brightness.dark,
      primaryColor: Color(0xFF7DC4FF),
      scaffoldBackgroundColor: Color(0xFF09121F),
    ),
    home: _SecondaryDisplaySurface(routeId: routeId),
  );
}

class _SecondaryDisplaySurface extends StatefulWidget {
  const _SecondaryDisplaySurface({required this.routeId});

  final String? routeId;

  @override
  State<_SecondaryDisplaySurface> createState() =>
      _SecondaryDisplaySurfaceState();
}

class _SecondaryDisplaySurfaceState extends State<_SecondaryDisplaySurface> {
  Timer? _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final turkish = locale.languageCode == 'tr';
    final routeId = widget.routeId;
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: routeId == 'dashboard.overview'
                  ? _DashboardSurface(now: _now, turkish: turkish)
                  : routeId == 'media.now-playing'
                  ? _MediaSurface(turkish: turkish)
                  : _UnavailableSurface(turkish: turkish),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardSurface extends StatelessWidget {
  const _DashboardSurface({required this.now, required this.turkish});

  final DateTime now;
  final bool turkish;

  @override
  Widget build(BuildContext context) {
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return Semantics(
      container: true,
      label: turkish ? 'Genel ev özeti' : 'Public home overview',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(CupertinoIcons.house_fill, size: 72),
          const SizedBox(height: 28),
          Text(
            '$hour:$minute',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.w700,
              letterSpacing: -2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            turkish ? 'Larenor ev ekranı' : 'Larenor home display',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(
            turkish
                ? 'Özel hesap ve ayar bilgileri tablet ekranında kalır.'
                : 'Private account and settings details stay on the tablet.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, color: Color(0xFFB5C4D8)),
          ),
        ],
      ),
    );
  }
}

class _MediaSurface extends StatelessWidget {
  const _MediaSurface({required this.turkish});

  final bool turkish;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: turkish
        ? 'Genel şimdi çalıyor ekranı'
        : 'Public now playing display',
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(CupertinoIcons.play_rectangle_fill, size: 96),
        const SizedBox(height: 28),
        Text(
          turkish ? 'Şimdi çalıyor' : 'Now playing',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        Text(
          turkish
              ? 'Oynatma ve özel medya ayrıntıları tablet ekranından yönetilir.'
              : 'Playback and private media details are controlled on the tablet.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, color: Color(0xFFB5C4D8)),
        ),
      ],
    ),
  );
}

class _UnavailableSurface extends StatelessWidget {
  const _UnavailableSurface({required this.turkish});

  final bool turkish;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(CupertinoIcons.exclamationmark_shield_fill, size: 72),
        const SizedBox(height: 24),
        Text(
          turkish ? 'Harici görev kullanılamıyor' : 'External task unavailable',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}
