import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/web_panel/data/web_panel_data.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_data_screen.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_settings_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../dashboard/webview_tile_test.dart' show TestWebViewPlatform;

class Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://synthetic.invalid',
    token: 'synthetic-token',
  );
  void replace() => state = const AsyncData(
    HaConnectionConfig(
      baseUrl: 'https://new.invalid',
      token: 'other-synthetic-token',
    ),
  );
}

class Pin extends PinLockStore {
  String? pin = '1234';
  Completer<PinAttemptResult>? verification;
  int attempts = 0;
  @override
  Future<String?> read() async => pin;
  @override
  Future<PinAttemptResult> verify(String candidate) async {
    attempts++;
    return verification == null
        ? PinAttemptResult(accepted: candidate == pin)
        : await verification!.future;
  }
}

class Api extends WebPanelDataApi {
  int clears = 0;
  @override
  Future<void> clearCookies() async {
    clears++;
  }

  @override
  Future<void> clearLocalStorage() async {}
  @override
  Future<void> clearCache() async {}
}

const tile = TileConfig(
  id: 'web',
  type: TileType.webview,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
  url: 'https://panel.invalid',
);

class Harness {
  final interaction = AppInteractionController();
  final platform = TestWebViewPlatform();
  final pin = Pin();
  final api = Api();
  late WebPanelDataCoordinator coordinator;
  late ProviderContainer container;
  TileConfig? saved;
  late AppLocalizations l10n;
  Future<void> mount(
    WidgetTester tester, {
    bool data = false,
    Size size = const Size(600, 1100),
    double scale = 1,
  }) async {
    coordinator = WebPanelDataCoordinator(api: api);
    container = ProviderContainer(
      overrides: [
        connectionConfigProvider.overrideWith(Connection.new),
        pinLockStoreProvider.overrideWith((ref) => pin),
      ],
    );
    final connectionLease = container.listen(
      connectionConfigProvider,
      (_, _) {},
    );
    final pinLease = container.listen(pinLockProvider, (_, _) {});
    await container.read(connectionConfigProvider.future);
    await container.read(pinLockProvider.future);
    final old = WebViewPlatform.instance;
    WebViewPlatform.instance = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.reset();
      WebViewPlatform.instance = old ?? TestWebViewPlatform();
      connectionLease.close();
      pinLease.close();
      container.dispose();
      interaction.dispose();
      coordinator.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: AppInteractionScope(
          controller: interaction,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                l10n = AppLocalizations.of(context);
                return CupertinoPageScaffold(
                  child: Center(
                    child: CupertinoButton(
                      child: const Text('Open'),
                      onPressed: () async {
                        saved = await Navigator.of(context).push<TileConfig>(
                          CupertinoPageRoute(
                            builder: (_) => data
                                ? WebPanelDataScreen(coordinator: coordinator)
                                : const WebPanelSettingsScreen(
                                    initialTile: tile,
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
    }
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> authorize(WidgetTester tester) async {
    await tap(tester, find.byKey(const ValueKey('web-data-clear')));
    await tester.enterText(
      find.byKey(const ValueKey('backup-reauth-pin')),
      '1234',
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final opaque in [true, false]) {
    testWidgets(
      'unrelated route cover (opaque=$opaque) cannot revive a source draft',
      (tester) async {
        final h = Harness();
        await h.mount(tester);
        final saved = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('web-settings-save')),
            )
            .onPressed!;
        final context = tester.element(find.byType(WebPanelSettingsScreen));
        final navigator = Navigator.of(context);
        final Route<void> route = opaque
            ? CupertinoPageRoute<void>(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Other page')),
              )
            : CupertinoDialogRoute<void>(
                context: context,
                builder: (_) =>
                    const CupertinoAlertDialog(title: Text('Other dialog')),
              );
        unawaited(navigator.push(route));
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        saved();
        await tester.pumpAndSettle();
        expect(h.saved, null);
        expect(find.text(h.l10n.dashboardWidgetPickerExpired), findsOneWidget);
        expect(tester.takeException(), null);
        await h.close(tester);
      },
    );
  }
  testWidgets(
    'URL and approved exact origin save a draft without starting renderer',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('web-settings-url')),
        'https://panel.invalid/new',
      );
      await tester.enterText(
        find.byKey(const ValueKey('web-settings-origin')),
        'https://LOGIN.invalid:8443/',
      );
      await h.tap(tester, find.text(h.l10n.webPanelOriginAdd));
      expect(find.textContaining('https://login.invalid:8443'), findsOneWidget);
      final callback = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('web-origin-confirm')),
          )
          .onPressed!;
      callback();
      callback();
      await tester.pumpAndSettle();
      await h.tap(tester, find.byKey(const ValueKey('web-settings-save')));
      expect(h.saved?.url, 'https://panel.invalid/new');
      expect(h.saved?.webPanel?.additionalOrigins, [
        'https://login.invalid:8443',
      ]);
      expect(h.platform.controllers, isEmpty);
      await h.close(tester);
    },
  );
  testWidgets('origin cancel retains no new grant', (tester) async {
    final h = Harness();
    await h.mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('web-settings-origin')),
      'https://login.invalid',
    );
    await h.tap(tester, find.text(h.l10n.webPanelOriginAdd));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await h.tap(tester, find.byKey(const ValueKey('web-settings-save')));
    expect(h.saved?.webPanel?.additionalOrigins, isEmpty);
    await h.close(tester);
  });
  for (final invalidation in ['account', 'idle', 'background']) {
    testWidgets(
      '$invalidation expires pending origin approval and old save callback',
      (tester) async {
        final h = Harness();
        await h.mount(tester);
        await tester.enterText(
          find.byKey(const ValueKey('web-settings-origin')),
          'https://login.invalid',
        );
        final save = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('web-settings-save')),
            )
            .onPressed!;
        await h.tap(tester, find.text(h.l10n.webPanelOriginAdd));
        final old = tester
            .widget<CupertinoDialogAction>(
              find.byKey(const ValueKey('web-origin-confirm')),
            )
            .onPressed!;
        if (invalidation == 'account') {
          (h.container.read(connectionConfigProvider.notifier) as Connection)
              .replace();
        }
        if (invalidation == 'idle') {
          h.interaction.setActive(false);
          h.interaction.setActive(true);
        }
        if (invalidation == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        await tester.pumpAndSettle();
        old();
        save();
        await tester.pumpAndSettle();
        expect(h.saved, null);
        expect(find.text(h.l10n.dashboardWidgetPickerExpired), findsOneWidget);
        expect(h.platform.controllers, isEmpty);
        expect(tester.takeException(), null);
        await h.close(tester);
      },
    );
  }
  testWidgets(
    'global clear requires PIN and explicit all-websites confirmation',
    (tester) async {
      final h = Harness();
      await h.mount(tester, data: true);
      await h.authorize(tester);
      expect(h.pin.attempts, 1);
      expect(h.api.clears, 0);
      final callback = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('web-data-confirm')),
          )
          .onPressed!;
      callback();
      callback();
      await tester.pumpAndSettle();
      expect(h.api.clears, 1);
      expect(find.text(h.l10n.webPanelDataDone), findsOneWidget);
      await h.close(tester);
    },
  );
  testWidgets(
    'global clear cancel and stale idle confirmation perform zero clears',
    (tester) async {
      final h = Harness();
      await h.mount(tester, data: true);
      await h.authorize(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.api.clears, 0);
      await h.authorize(tester);
      final callback = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('web-data-confirm')),
          )
          .onPressed!;
      h.interaction.setActive(false);
      h.interaction.setActive(true);
      await tester.pumpAndSettle();
      callback();
      await tester.pumpAndSettle();
      expect(h.api.clears, 0);
      expect(tester.takeException(), null);
      await h.close(tester);
    },
  );
  testWidgets('no PIN exposes no global destructive action', (tester) async {
    final h = Harness()..pin.pin = null;
    await h.mount(tester, data: true);
    expect(find.byKey(const ValueKey('web-data-clear')), findsNothing);
    expect(h.api.clears, 0);
    await h.close(tester);
  });
  for (final size in [const Size(320, 1100), const Size(1280, 1000)]) {
    testWidgets('settings and data pages fit $size with large text', (
      tester,
    ) async {
      final h = Harness();
      await h.mount(tester, size: size, scale: 2);
      await h.tap(tester, find.byKey(const ValueKey('web-settings-save')));
      expect(h.saved, isNotNull);
      expect(tester.takeException(), null);
      await h.close(tester);
    });
  }
}
