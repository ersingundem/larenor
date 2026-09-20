import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/arr/data/arr_config.dart';
import 'package:larenor/features/media/arr/presentation/lidarr_screen.dart';
import 'package:larenor/features/media/arr/presentation/radarr_screen.dart';
import 'package:larenor/features/media/arr/presentation/readarr_screen.dart';
import 'package:larenor/features/media/arr/presentation/sonarr_screen.dart';
import 'package:larenor/features/media/arr/providers/lidarr_providers.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/readarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _RadarrConnection extends RadarrConnection {
  _RadarrConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<ArrConfig?> build() async {
    onRead();
    throw StateError('private Radarr diagnostic');
  }
}

class _SonarrConnection extends SonarrConnection {
  _SonarrConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<ArrConfig?> build() async {
    onRead();
    throw StateError('private Sonarr diagnostic');
  }
}

class _LidarrConnection extends LidarrConnection {
  _LidarrConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<ArrConfig?> build() async {
    onRead();
    throw StateError('private Lidarr diagnostic');
  }
}

class _ReadarrConnection extends ReadarrConnection {
  _ReadarrConnection(this.onRead);
  final VoidCallback onRead;
  @override
  Future<ArrConfig?> build() async {
    onRead();
    throw StateError('private Readarr diagnostic');
  }
}

typedef _BuildCase = Widget Function(VoidCallback onRead);

class _RouteCase {
  const _RouteCase(this.name, this.routeKey, this.build);
  final String name;
  final String routeKey;
  final _BuildCase build;
}

Widget _app(Widget home) => CupertinoApp(
  theme: larenorTheme(),
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

final _cases = [
  _RouteCase(
    'Radarr',
    'radarr',
    (onRead) => ProviderScope(
      key: const ValueKey('radarr-scope'),
      overrides: [
        radarrConnectionProvider.overrideWith(() => _RadarrConnection(onRead)),
      ],
      child: _app(const RadarrScreen()),
    ),
  ),
  _RouteCase(
    'Sonarr',
    'sonarr',
    (onRead) => ProviderScope(
      key: const ValueKey('sonarr-scope'),
      overrides: [
        sonarrConnectionProvider.overrideWith(() => _SonarrConnection(onRead)),
      ],
      child: _app(const SonarrScreen()),
    ),
  ),
  _RouteCase(
    'Lidarr',
    'lidarr',
    (onRead) => ProviderScope(
      key: const ValueKey('lidarr-scope'),
      overrides: [
        lidarrConnectionProvider.overrideWith(() => _LidarrConnection(onRead)),
      ],
      child: _app(const LidarrScreen()),
    ),
  ),
  _RouteCase(
    'Readarr',
    'readarr',
    (onRead) => ProviderScope(
      key: const ValueKey('readarr-scope'),
      overrides: [
        readarrConnectionProvider.overrideWith(
          () => _ReadarrConnection(onRead),
        ),
      ],
      child: _app(const ReadarrScreen()),
    ),
  ),
];

Future<void> _tabToRetry(WidgetTester tester, Key key) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == key) return;
  }
  fail('The Arr retry action is not reachable with Tab.');
}

void main() {
  for (final width in [600.0, 1200.0]) {
    testWidgets('Arr roots share private live tablet states $width 2x', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        for (final route in _cases) {
          var reads = 0;
          await tester.pumpWidget(route.build(() => reads++));
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(
            tester.element(find.byType(AppSurface)),
          );
          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.text(route.name), findsWidgets);
          expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
          expect(
            find.textContaining('private ${route.name} diagnostic'),
            findsNothing,
          );

          final statusKey = ValueKey('${route.routeKey}-home-status');
          final retryKey = ValueKey('${route.routeKey}-home-retry');
          final status = tester.getSemantics(find.byKey(statusKey));
          expect(status.label, l10n.mediaErrorUnreachable);
          expect(status.flagsCollection.isLiveRegion, isTrue);
          final retry = tester.getSemantics(find.byKey(retryKey));
          expect(retry.label, l10n.commonRetry);
          expect(retry.flagsCollection.isButton, isTrue);
          expect(retry.rect.height, greaterThanOrEqualTo(48));

          await _tabToRetry(tester, retryKey);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(reads, 2);
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
      }
    });
  }
}
