import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_config.dart';
import 'package:larenor/features/media/bazarr/presentation/bazarr_connect_screen.dart';
import 'package:larenor/features/media/bazarr/presentation/bazarr_home_screen.dart';
import 'package:larenor/features/media/bazarr/providers/bazarr_providers.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/presentation/jellyseerr_connect_screen.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/media/prowlarr/data/prowlarr_config.dart';
import 'package:larenor/features/media/prowlarr/presentation/prowlarr_connect_screen.dart';
import 'package:larenor/features/media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import 'package:larenor/features/media/prowlarr/providers/prowlarr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';

class _FailingBazarrConnection extends BazarrConnection {
  _FailingBazarrConnection(this.onRead);
  final VoidCallback onRead;

  @override
  Future<BazarrConfig?> build() async {
    onRead();
    throw StateError('private Bazarr diagnostic');
  }
}

class _FailingProwlarrConnection extends ProwlarrConnection {
  _FailingProwlarrConnection(this.onRead);
  final VoidCallback onRead;

  @override
  Future<ProwlarrConfig?> build() async {
    onRead();
    throw StateError('private Prowlarr diagnostic');
  }
}

class _FailingJellyseerrConnection extends JellyseerrConnection {
  _FailingJellyseerrConnection(this.onRead);
  final VoidCallback onRead;

  @override
  Future<JellyseerrConfig?> build() async {
    onRead();
    throw StateError('private Jellyseerr diagnostic');
  }
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

Future<void> _tabTo(WidgetTester tester, Key key) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == key) return;
  }
  fail('The service retry action is not reachable with Tab.');
}

void _expectStatus(
  WidgetTester tester, {
  required String service,
  required String statusKey,
  required String retryKey,
  required String privateDiagnostic,
}) {
  final l10n = AppLocalizations.of(tester.element(find.byType(AppSurface)));
  expect(find.byType(AppSurface), findsOneWidget);
  expect(find.text(service), findsOneWidget);
  expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
  expect(find.textContaining(privateDiagnostic), findsNothing);
  final status = tester.getSemantics(find.byKey(ValueKey(statusKey)));
  expect(status.label, l10n.mediaErrorUnreachable);
  expect(status.flagsCollection.isLiveRegion, isTrue);
  final retry = tester.getSemantics(find.byKey(ValueKey(retryKey)));
  expect(retry.label, l10n.commonRetry);
  expect(retry.flagsCollection.isButton, isTrue);
  expect(retry.rect.height, greaterThanOrEqualTo(48));
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('Bazarr and Prowlarr adopt shared private service state '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var bazarrReads = 0;
      var prowlarrReads = 0;
      try {
        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('bazarr-scope'),
            overrides: [
              bazarrConnectionProvider.overrideWith(
                () => _FailingBazarrConnection(() => bazarrReads++),
              ),
            ],
            child: _app(const BazarrHomeScreen()),
          ),
        );
        await tester.pumpAndSettle();
        _expectStatus(
          tester,
          service: 'Bazarr',
          statusKey: 'bazarr-home-status',
          retryKey: 'bazarr-home-retry',
          privateDiagnostic: 'private Bazarr diagnostic',
        );
        await _tabTo(tester, const ValueKey('bazarr-home-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(bazarrReads, 2);

        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('prowlarr-scope'),
            overrides: [
              prowlarrConnectionProvider.overrideWith(
                () => _FailingProwlarrConnection(() => prowlarrReads++),
              ),
            ],
            child: _app(const ProwlarrIndexersScreen()),
          ),
        );
        await tester.pumpAndSettle();
        _expectStatus(
          tester,
          service: 'Prowlarr',
          statusKey: 'prowlarr-indexers-status',
          retryKey: 'prowlarr-indexers-retry',
          privateDiagnostic: 'private Prowlarr diagnostic',
        );
        await _tabTo(tester, const ValueKey('prowlarr-indexers-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(prowlarrReads, 2);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('service connect routes share private recovery state '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        var jellyseerrReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('jellyseerr-connect-scope'),
            overrides: [
              jellyseerrConnectionProvider.overrideWith(
                () => _FailingJellyseerrConnection(() => jellyseerrReads++),
              ),
            ],
            child: _app(const JellyseerrConnectScreen()),
          ),
        );
        await tester.pumpAndSettle();
        _expectStatus(
          tester,
          service: 'Jellyseerr',
          statusKey: 'jellyseerr-connect-status',
          retryKey: 'jellyseerr-connect-retry',
          privateDiagnostic: 'private Jellyseerr diagnostic',
        );
        await _tabTo(tester, const ValueKey('jellyseerr-connect-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(jellyseerrReads, 2);

        var bazarrReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('bazarr-connect-scope'),
            overrides: [
              bazarrConnectionProvider.overrideWith(
                () => _FailingBazarrConnection(() => bazarrReads++),
              ),
            ],
            child: _app(const BazarrConnectScreen()),
          ),
        );
        await tester.pumpAndSettle();
        _expectStatus(
          tester,
          service: 'Bazarr',
          statusKey: 'bazarr-connect-status',
          retryKey: 'bazarr-connect-retry',
          privateDiagnostic: 'private Bazarr diagnostic',
        );
        await _tabTo(tester, const ValueKey('bazarr-connect-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(bazarrReads, 2);

        var prowlarrReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('prowlarr-connect-scope'),
            overrides: [
              prowlarrConnectionProvider.overrideWith(
                () => _FailingProwlarrConnection(() => prowlarrReads++),
              ),
            ],
            child: _app(const ProwlarrConnectScreen()),
          ),
        );
        await tester.pumpAndSettle();
        _expectStatus(
          tester,
          service: 'Prowlarr',
          statusKey: 'prowlarr-connect-status',
          retryKey: 'prowlarr-connect-retry',
          privateDiagnostic: 'private Prowlarr diagnostic',
        );
        await _tabTo(tester, const ValueKey('prowlarr-connect-retry'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(prowlarrReads, 2);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
