// Synthetic retained AsyncValue fixtures exercise loading/error privacy guards.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/presentation/ha_frontend_screen.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';
import 'package:larenor/features/web_panel/domain/web_panel_options.dart';
import 'package:larenor/features/web_panel/data/web_panel_data.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_view.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../dashboard/webview_tile_test.dart' show TestWebViewPlatform;
import 'web_panel_data_test.dart' show Api;

class Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://fixture.invalid',
    token: 'synthetic-secret-token',
  );
  void replace() => state = const AsyncData(
    HaConnectionConfig(
      baseUrl: 'https://fixture.invalid',
      token: 'different-synthetic-token',
    ),
  );
  void loading() =>
      state = const AsyncLoading<HaConnectionConfig?>().copyWithPrevious(state);
  void fail() => state = AsyncError<HaConnectionConfig?>(
    StateError('private-error'),
    StackTrace.empty,
  ).copyWithPrevious(state);
}

class Harness {
  final platform = TestWebViewPlatform();
  final interaction = AppInteractionController();
  final nav = GlobalKey<NavigatorState>();
  final panel = GlobalKey<WebPanelViewState>();
  late ProviderContainer container;
  late AppLocalizations l10n;
  Future<void> mount(
    WidgetTester tester, {
    bool ha = false,
    Size? size,
    double scale = 1,
    WebPanelOptions? options,
    WebPanelDataCoordinator? coordinator,
  }) async {
    final previous = WebViewPlatform.instance;
    WebViewPlatform.instance = platform;
    container = ProviderContainer(
      overrides: [
        connectionConfigProvider.overrideWith(Connection.new),
        haWebSocketClientProvider.overrideWithValue(null),
        haRestClientProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() {
      WebViewPlatform.instance = previous ?? TestWebViewPlatform();
      container.dispose();
      interaction.dispose();
    });
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: AppInteractionScope(
          controller: interaction,
          child: CupertinoApp(
            navigatorKey: nav,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                l10n = AppLocalizations.of(context);
                return ha
                    ? const HaFrontendScreen()
                    : CupertinoPageScaffold(
                        child: WebPanelView(
                          key: panel,
                          options: options,
                          dataCoordinator: coordinator,
                          policy:
                              options?.policyFor(
                                'https://fixture.invalid/start',
                              ) ??
                              WebPanelPolicy.fromUrl(
                                'https://fixture.invalid/start?token=fixture-secret',
                              ),
                        ),
                      );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }
}

void pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
    'explicit source origins and zoom preferences reach only the configured panel',
    (tester) async {
      final h = Harness();
      await h.mount(
        tester,
        options: WebPanelOptions(
          additionalOrigins: ['https://login.invalid:8443'],
          zoomEnabled: false,
        ),
      );
      final controller = h.platform.controllers.single;
      expect(controller.zoomOptions, [false]);
      expect(
        await controller.delegate.navigation(
          const NavigationRequest(
            url: 'https://login.invalid:8443/oauth',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.navigate,
      );
      expect(
        await controller.delegate.navigation(
          const NavigationRequest(
            url: 'https://login.invalid/oauth',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await h.close(tester);
    },
  );
  testWidgets(
    'global clear retires old callbacks and blocks restart until native clear finishes',
    (tester) async {
      final api = Api()..cookies = Completer<void>();
      final data = WebPanelDataCoordinator(api: api);
      final h = Harness();
      await h.mount(tester, coordinator: data);
      final old = h.platform.controllers.single;
      final pending = data.clear(isCurrent: () => true);
      await tester.pump();
      expect(old.html, ['<html></html>']);
      expect(
        await old.delegate.navigation(
          const NavigationRequest(
            url: 'https://fixture.invalid/next',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      h.panel.currentState!.restart();
      await tester.pump();
      expect(h.platform.controllers, hasLength(1));
      api.cookies!.complete();
      expect(await pending, true);
      await tester.pump();
      await tester.pump();
      expect(h.platform.controllers, hasLength(2));
      expect(h.platform.controllers.last.requests, hasLength(1));
      old.delegate.finished('https://fixture.invalid/old');
      await tester.pump();
      expect(old.requests, hasLength(1));
      await h.close(tester);
      data.dispose();
    },
  );
  testWidgets('late HA setup cannot navigate after account changes', (
    tester,
  ) async {
    final h = Harness();
    final pending = Completer<void>();
    h.platform.nextDelegateGate = pending;
    await h.mount(tester, ha: true);
    final old = h.platform.controllers.single;
    (h.container.read(connectionConfigProvider.notifier) as Connection)
        .replace();
    pending.complete();
    await tester.pump();
    expect(old.requests, isEmpty);
    expect(h.container.exists(haRestClientProvider), false);
    expect(h.container.exists(haWebSocketClientProvider), false);
    await h.close(tester);
  });
  testWidgets(
    'back navigation has one pending request and no duplicate history step',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final current = h.platform.controllers.single;
      current.backGate = Completer<bool>();
      final first = h.panel.currentState!.back();
      final duplicate = h.panel.currentState!.back();
      expect(await duplicate, true);
      current.backGate!.complete(true);
      expect(await first, true);
      expect(current.backCalls, 1);
      await h.close(tester);
    },
  );
  testWidgets(
    'native JavaScript dialogs receive no confirmation or private value',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final current = h.platform.controllers.single;
      expect(
        await current.confirm(
          const JavaScriptConfirmDialogRequest(
            message: 'Site requests privileged operation',
            url: 'https://fixture.invalid/private',
          ),
        ),
        false,
      );
      expect(
        await current.prompt(
          const JavaScriptTextInputDialogRequest(
            message: 'Enter API secret',
            url: 'https://fixture.invalid',
            defaultText: 'untrusted-default',
          ),
        ),
        '',
      );
      await current.alert(
        const JavaScriptAlertDialogRequest(
          message: 'Untrusted alert',
          url: 'https://fixture.invalid',
        ),
      );
      expect(find.textContaining('API secret'), findsNothing);
      await h.close(tester);
    },
  );
  testWidgets(
    'different origin blocks and never renders URL query or error payload',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final old = h.platform.controllers.single;
      expect(
        await old.delegate.navigation(
          const NavigationRequest(
            url: 'https://foreign.invalid/private?secret=value',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await tester.pump();
      expect(old.html, ['<html></html>']);
      expect(find.text(h.l10n.webPanelBlocked), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(old.requests, hasLength(1));
      expect(
        await old.delegate.navigation(
          const NavigationRequest(
            url: 'https://fixture.invalid/next',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await h.close(tester);
    },
  );
  testWidgets(
    'unexpected committed URL retires page even without navigation request',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final old = h.platform.controllers.single;
      old.delegate.urlChange(const UrlChange(url: 'https://foreign.invalid/'));
      await tester.pump();
      expect(find.text(h.l10n.webPanelBlocked), findsOneWidget);
      expect(old.html, ['<html></html>']);
      await h.close(tester);
    },
  );
  testWidgets('redirect loop hits budget; manual duplicate retries load once', (
    tester,
  ) async {
    final h = Harness();
    await h.mount(tester);
    final old = h.platform.controllers.single;
    for (var i = 0; i < 20; i++) {
      expect(
        await old.delegate.navigation(
          NavigationRequest(
            url: 'https://fixture.invalid/$i',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.navigate,
      );
    }
    expect(
      await old.delegate.navigation(
        const NavigationRequest(
          url: 'https://fixture.invalid/again',
          isMainFrame: true,
        ),
      ),
      NavigationDecision.prevent,
    );
    await tester.pump();
    h.panel.currentState!.restart();
    h.panel.currentState!.restart();
    await tester.pump();
    expect(h.platform.controllers, hasLength(2));
    expect(h.platform.controllers.last.requests, hasLength(1));
    await h.close(tester);
  });
  testWidgets('load and setup deadlines stop pages without automatic retry', (
    tester,
  ) async {
    final h = Harness();
    await h.mount(tester);
    await tester.pump(const Duration(seconds: 31));
    expect(find.text(h.l10n.webPanelTimedOut), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(h.platform.controllers, hasLength(1));
    expect(h.platform.controllers.single.html, ['<html></html>']);
    await h.close(tester);
  });
  testWidgets('late setup after deadline never sends initial request', (
    tester,
  ) async {
    final h = Harness();
    final pending = Completer<void>();
    h.platform.nextDelegateGate = pending;
    await h.mount(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text(h.l10n.webPanelTimedOut), findsOneWidget);
    pending.complete();
    await tester.pump();
    expect(h.platform.controllers.single.requests, isEmpty);
    await h.close(tester);
  });
  testWidgets(
    'idle lock invalidates callbacks immediately and clears website',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final old = h.platform.controllers.single;
      h.interaction.setActive(false);
      expect(
        await old.delegate.navigation(
          const NavigationRequest(
            url: 'https://fixture.invalid/',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-web-content')), findsNothing);
      expect(old.html, ['<html></html>']);
      await tester.pump(const Duration(minutes: 1));
      h.interaction.setActive(true);
      await tester.pump();
      expect(h.platform.controllers, hasLength(2));
      await h.close(tester);
    },
  );
  testWidgets(
    'covered route expires pending back without popping covering page',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final old = h.platform.controllers.single;
      old.backGate = Completer<bool>();
      final back = h.panel.currentState!.back();
      unawaited(
        h.nav.currentState!.push(
          CupertinoPageRoute<void>(
            builder: (_) =>
                const CupertinoPageScaffold(child: Text('Covering page')),
          ),
        ),
      );
      old.backGate!.complete(false);
      expect(await back, true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Covering page'), findsOneWidget);
      expect(old.backCalls, 0);
      expect(old.html, ['<html></html>']);
      await h.close(tester);
    },
  );
  for (final change in ['account', 'loading', 'error', 'background']) {
    testWidgets('HA frontend $change closes old website and late callbacks', (
      tester,
    ) async {
      final h = Harness();
      await h.mount(tester, ha: true);
      final old = h.platform.controllers.single;
      expect(old.requests.single.headers, isEmpty);
      expect(old.requests.single.uri.toString(), 'https://fixture.invalid');
      switch (change) {
        case 'account':
          (h.container.read(connectionConfigProvider.notifier) as Connection)
              .replace();
        case 'loading':
          (h.container.read(connectionConfigProvider.notifier) as Connection)
              .loading();
        case 'error':
          (h.container.read(connectionConfigProvider.notifier) as Connection)
              .fail();
        case 'background':
          pause(tester);
      }
      expect(
        await old.delegate.navigation(
          const NavigationRequest(
            url: 'https://fixture.invalid/next',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      await tester.pump();
      await tester.pump();
      expect(old.html, ['<html></html>']);
      expect(find.byKey(const ValueKey('fake-web-content')), findsNothing);
      expect(find.textContaining('synthetic'), findsNothing);
      if (change == 'background') {
        resume(tester);
        await tester.pump();
      }
      await h.close(tester);
    });
  }
  for (final size in [const Size(320, 700), const Size(1280, 900)]) {
    testWidgets('HA frontend error fits $size at enlarged text', (
      tester,
    ) async {
      final h = Harness();
      await h.mount(
        tester,
        ha: true,
        size: size,
        scale: size.width < 500 ? 2 : 1.6,
      );
      h.platform.controllers.single.delegate.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'private-url/token',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(find.text(h.l10n.webPanelLoadFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('private-url'), findsNothing);
      await h.close(tester);
    });
  }
}
