import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_connect_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_discovery.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_connect_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/qbittorrent/data/qbittorrent_config.dart';
import 'package:larenor/features/media/qbittorrent/presentation/qbittorrent_connect_screen.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import '../../core/direct_home_routines_test.dart' show routinesHome;

enum _Surface { keenetic, jellyfin, qbittorrent }

class _KeeneticConnection extends KeeneticConnection {
  int signIns = 0;

  @override
  Future<KeeneticConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return null;
  }

  @override
  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() != false) signIns++;
  }
}

class _JellyfinConnection extends JellyfinConnection {
  int signIns = 0;

  @override
  Future<JellyfinConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return null;
  }

  @override
  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() != false) signIns++;
  }
}

class _QbittorrentConnection extends QbittorrentConnection {
  int signIns = 0;

  @override
  Future<QbittorrentConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return null;
  }

  @override
  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() != false) signIns++;
  }
}

class _Harness {
  final keenetic = _KeeneticConnection();
  final jellyfin = _JellyfinConnection();
  final qbittorrent = _QbittorrentConnection();

  Widget screen(_Surface surface) => switch (surface) {
    _Surface.keenetic => const KeeneticConnectScreen(popOnSuccess: false),
    _Surface.jellyfin => const JellyfinConnectScreen(),
    _Surface.qbittorrent => const QbittorrentConnectScreen(popOnSuccess: false),
  };

  String actionKey(_Surface surface) => switch (surface) {
    _Surface.keenetic => 'keenetic-connect-submit',
    _Surface.jellyfin => 'jellyfin-connect-submit',
    _Surface.qbittorrent => 'qbittorrent-connect-submit',
  };

  int signIns(_Surface surface) => switch (surface) {
    _Surface.keenetic => keenetic.signIns,
    _Surface.jellyfin => jellyfin.signIns,
    _Surface.qbittorrent => qbittorrent.signIns,
  };

  Future<void> mount(
    WidgetTester tester, {
    required _Surface surface,
    required Locale locale,
    required double width,
  }) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (container, _) = await routinesHome('direct');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ProviderScope(
          overrides: [
            keeneticConnectionProvider.overrideWith(() => keenetic),
            jellyfinConnectionProvider.overrideWith(() => jellyfin),
            qbittorrentConnectionProvider.overrideWith(() => qbittorrent),
            jellyfinDiscoveryFactoryProvider.overrideWithValue(
              () => JellyfinDiscoveryService(
                bind: () async => throw const SocketException('fixture'),
              ),
            ),
          ],
          child: CupertinoApp(
            theme: larenorTheme(),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: screen(surface),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fillAndSubmit(WidgetTester tester, _Surface surface) async {
    final fields = find.byType(CupertinoTextField);
    switch (surface) {
      case _Surface.keenetic:
        await tester.enterText(fields.at(2), 'fixture-password');
      case _Surface.jellyfin:
      case _Surface.qbittorrent:
        await tester.enterText(fields.at(1), 'fixture-user');
        await tester.enterText(fields.at(2), 'fixture-password');
    }
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }
}

void _expectAction(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  expect(finder, findsOneWidget);
  final semantics = tester.getSemantics(finder);
  expect(semantics.flagsCollection.isButton, isTrue);
  expect(semantics.rect.width, greaterThanOrEqualTo(48));
  expect(semantics.rect.height, greaterThanOrEqualTo(48));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const networkChannel = MethodChannel(
    'dev.fluttercommunity.plus/network_info',
  );
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(networkChannel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(networkChannel, null);
  });

  for (final surface in _Surface.values) {
    for (final locale in const [Locale('en'), Locale('tr')]) {
      for (final width in const [600.0, 1200.0]) {
        testWidgets(
          '${surface.name} ${locale.languageCode} fits ${width.toInt()} at 2x and submits with Done',
          (tester) async {
            final semantics = tester.ensureSemantics();
            final harness = _Harness();
            await harness.mount(
              tester,
              surface: surface,
              locale: locale,
              width: width,
            );
            expect(find.byType(AppSurface), findsOneWidget);
            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            _expectAction(tester, harness.actionKey(surface));
            await harness.fillAndSubmit(tester, surface);
            expect(harness.signIns(surface), 1);
            expect(tester.takeException(), isNull);
            semantics.dispose();
          },
        );
      }
    }

    testWidgets('${surface.name} stale submit after background fails closed', (
      tester,
    ) async {
      final harness = _Harness();
      await harness.mount(
        tester,
        surface: surface,
        locale: const Locale('en'),
        width: 600,
      );
      final oldSubmit = tester
          .widget<CupertinoButton>(
            find.byKey(ValueKey(harness.actionKey(surface))),
          )
          .onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      oldSubmit();
      await tester.pumpAndSettle();
      expect(harness.signIns(surface), 0);
      expect(tester.takeException(), isNull);
    });
  }
}
