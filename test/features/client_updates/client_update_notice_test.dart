import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/features/client_updates/data/client_release_repository.dart';
import 'package:larenor/features/client_updates/domain/client_update_models.dart';
import 'package:larenor/features/client_updates/presentation/client_update_notice.dart';
import 'package:larenor/features/client_updates/presentation/client_updates_screen.dart';
import 'package:larenor/features/client_updates/providers/client_update_providers.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../server/server_account_test.dart' as accounts;
import '../navigation/app_navigation_test.dart' show openApp;
import 'client_updates_test.dart' as updates;

class NoticeApi extends updates.FakeApi {
  int snapshots = 0;
  InstalledClientSnapshot installed = InstalledClientSnapshot.fromChannel(
    updates.installedJson(),
  );
  @override
  Future<InstalledClientSnapshot> snapshot() async {
    snapshots++;
    return pendingSnapshot == null ? installed : await pendingSnapshot!.future;
  }
}

class NoticeHarness {
  final api = NoticeApi();
  final store = accounts.MemorySessions();
  final interaction = AppInteractionController();
  final visible = ValueNotifier(true);
  final location = ValueNotifier('/');
  final navigator = GlobalKey<NavigatorState>();
  late final ServerAccountController account;
  http.Response response = http.Response(
    jsonEncode(updates.releaseJson()),
    200,
  );
  Completer<http.Response>? pending;
  Completer<http.Response>? pendingLogin;
  int reads = 0, closed = 0, accountReads = 0, refreshes = 0;
  bool failRefresh = false;

  Future<void> mount(
    WidgetTester tester, {
    bool login = true,
    bool saved = false,
    bool expired = false,
    String? pin,
    double scale = 1,
    Size size = const Size(900, 1000),
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
    account = ServerAccountController(
      store: store,
      clock: () => accounts.now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        clock: () => accounts.now,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/me')) {
            accountReads++;
            return accounts.jsonResponse({
              'user': accounts.pair(change: false)['user'],
            });
          }
          if (request.url.path.endsWith('/health')) {
            return accounts.jsonResponse({
              'service': 'larenor-server',
              'apiVersion': 1,
            });
          }
          if (request.url.path.endsWith('/refresh')) {
            refreshes++;
            if (failRefresh) throw const LarenorServerException('timeout');
          }
          if (request.url.path.endsWith('/login') && pendingLogin != null) {
            return pendingLogin!.future;
          }
          return accounts.jsonResponse(accounts.pair(change: false));
        }),
      ),
    );
    if (saved) {
      store.value = ServerSession.fromResponse(
        ServerEndpoint('https://server.test'),
        accounts.pair(change: false),
        now: expired
            ? accounts.now.subtract(const Duration(hours: 1))
            : accounts.now,
      );
    }
    if (login) await signIn();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account),
          clientUpdateApiProvider.overrideWithValue(api),
          clientReleaseFactoryProvider.overrideWithValue(
            (source) => _NoticeRepository(
              source.baseUrl,
              source.accessToken,
              source.isCurrent,
              () => closed++,
              MockClient((request) async {
                expect(request.method, 'GET');
                expect(request.url.path, '/api/v1/client/releases/latest');
                reads++;
                return pending == null ? response : await pending!.future;
              }),
            ),
          ),
        ],
        child: CupertinoApp(
          navigatorKey: navigator,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => AppInteractionScope(
            controller: interaction,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
          home: CupertinoPageScaffold(
            child: Column(
              children: [
                ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (context, enabled, _) => TickerMode(
                    enabled: enabled,
                    child: ValueListenableBuilder(
                      valueListenable: location,
                      builder: (context, path, _) => ClientUpdateNotice(
                        location: path,
                        onOpen: () => navigator.currentState!.push(
                          CupertinoPageRoute<void>(
                            builder: (_) => const SettingsGateScreen(
                              initialDestination:
                                  SettingsGateDestination.clientUpdates,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Expanded(child: Center(child: Text('Home content'))),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
      interaction.dispose();
      visible.dispose();
      location.dispose();
      await api.events.close();
    });
  }

  Future<void> signIn() => account.signIn(
    baseUrl: 'https://server.test',
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'Test tablet',
  );
}

class _NoticeRepository extends ClientReleaseRepository {
  _NoticeRepository(
    String url,
    String token,
    bool Function() current,
    this.onClose,
    http.Client client,
  ) : super(
        baseUrl: url,
        accessToken: token,
        isCurrent: current,
        clientFactory: () => client,
      );
  final VoidCallback onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  final banner = find.byKey(const ValueKey('client-update-notice'));

  testWidgets(
    'start and interval only read metadata; dismissal is session-only',
    (tester) async {
      final h = NoticeHarness();
      await h.mount(tester);
      expect(h.reads, 1);
      expect(banner, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('client-update-dismiss')));
      await tester.pump();
      expect(banner, findsNothing);
      await tester.pump(const Duration(minutes: 14));
      expect(h.reads, 1);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(h.reads, 2);
      expect(banner, findsNothing);
      h.response = http.Response(
        jsonEncode({
          ...updates.releaseJson(),
          'versionCode': 21,
          'versionName': '2.1',
          'downloadPath': '/api/v1/client/releases/21/apk',
        }),
        200,
      );
      await tester.pump(const Duration(minutes: 15));
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      expect(h.api.downloads, 0);
      expect(h.api.installs, 0);
      expect(h.api.settings, 0);
      expect(h.api.session, isNull);
    },
  );

  testWidgets('restore validates saved account once without recursive checks', (
    tester,
  ) async {
    final h = NoticeHarness();
    await h.mount(tester, login: false, saved: true);
    expect(h.accountReads, 1);
    expect(h.reads, 1);
    expect(banner, findsOneWidget);
    await tester.pumpAndSettle();
    expect(h.reads, 1);
  });

  testWidgets('uncertain saved refresh is not retried on timer or resume', (
    tester,
  ) async {
    final h = NoticeHarness()..failRefresh = true;
    await h.mount(tester, login: false, saved: true, expired: true);
    expect(h.refreshes, 1);
    expect(h.reads, 0);
    await tester.pump(const Duration(minutes: 16));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(h.refreshes, 1);
    expect(banner, findsNothing);
  });

  testWidgets('expired saved session rotates once before checking a release', (
    tester,
  ) async {
    final h = NoticeHarness();
    await h.mount(tester, login: false, saved: true, expired: true);
    expect(h.refreshes, 1);
    expect(h.reads, 1);
    expect(banner, findsOneWidget);
    expect(h.api.session, isNull);
  });

  for (final kind in [
    'no release',
    'wrong signer',
    'current version',
    'downgrade',
    'wrong package',
    'invalid minimum SDK',
    'unsupported',
  ]) {
    testWidgets('$kind is never advertised', (tester) async {
      final h = NoticeHarness();
      if (kind == 'no release') h.response = http.Response('', 204);
      if (kind == 'wrong signer') {
        h.response = http.Response(
          jsonEncode({...updates.releaseJson(), 'certificateSha256': 'd' * 64}),
          200,
        );
      }
      if (kind == 'current version') {
        h.api.installed = InstalledClientSnapshot.fromChannel({
          ...updates.installedJson(),
          'versionCode': 20,
        });
      }
      if (kind == 'downgrade') {
        h.api.installed = InstalledClientSnapshot.fromChannel({
          ...updates.installedJson(),
          'versionCode': 21,
        });
      }
      if (kind == 'wrong package' || kind == 'invalid minimum SDK') {
        h.response = http.Response(
          jsonEncode({
            ...updates.releaseJson(),
            if (kind == 'wrong package') 'applicationId': 'other.package',
            if (kind == 'invalid minimum SDK') 'minSdk': 100,
          }),
          200,
        );
      }
      if (kind == 'unsupported') {
        h.api.installed = const InstalledClientSnapshot.unsupported();
      }
      await h.mount(tester);
      expect(banner, findsNothing);
      expect(h.api.downloads, 0);
      expect(h.api.installs, 0);
      if (kind == 'unsupported') expect(h.reads, 0);
    });
  }

  testWidgets('logout expires a delayed release and old open callback', (
    tester,
  ) async {
    final h = NoticeHarness();
    await h.mount(tester);
    final open = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('client-update-open')),
        )
        .onPressed!;
    h.pending = Completer<http.Response>();
    await tester.pump(const Duration(minutes: 15));
    await tester.pump();
    expect(h.reads, 2);
    final closed = h.closed;
    await h.account.signOut();
    await tester.pump();
    expect(h.closed, greaterThan(closed));
    h.pending!.complete(h.response);
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(find.byType(SettingsGateScreen), findsNothing);
  });

  testWidgets('replacement account cannot receive the old delayed release', (
    tester,
  ) async {
    final h = NoticeHarness()..pending = Completer<http.Response>();
    await h.mount(tester);
    await h.account.signOut();
    await h.signIn();
    await tester.pumpAndSettle();
    expect(h.reads, 1);
    final old = h.pending!;
    h.pending = null;
    h.response = http.Response('', 204);
    old.complete(http.Response(jsonEncode(updates.releaseJson()), 200));
    await tester.pumpAndSettle();
    expect(h.reads, 2);
    expect(banner, findsNothing);
  });

  testWidgets(
    'pending native snapshot cannot overlap interval or resume checks',
    (tester) async {
      final h = NoticeHarness();
      h.api.pendingSnapshot = Completer<InstalledClientSnapshot>();
      await h.mount(tester);
      expect(h.api.snapshots, 1);
      await tester.pump(const Duration(minutes: 30));
      h.visible.value = false;
      await tester.pump();
      h.visible.value = true;
      await tester.pump();
      expect(h.api.snapshots, 1);
      final old = h.api.pendingSnapshot!;
      h.api.pendingSnapshot = null;
      old.complete(h.api.installed);
      await tester.pumpAndSettle();
      expect(h.api.snapshots, 2);
      expect(h.reads, 1);
      expect(h.api.downloads, 0);
    },
  );

  testWidgets('initially hidden notice restores no account until visible', (
    tester,
  ) async {
    final h = NoticeHarness();
    h.visible.value = false;
    await h.mount(tester, login: false, saved: true);
    expect(h.api.snapshots, 0);
    expect(h.accountReads, 0);
    await tester.pump(const Duration(minutes: 30));
    expect(h.reads, 0);
    h.visible.value = true;
    await tester.pumpAndSettle();
    expect(h.accountReads, 1);
    expect(h.reads, 1);
  });

  testWidgets(
    'hidden, idle and covered routes cancel reads and stop the timer',
    (tester) async {
      final h = NoticeHarness();
      await h.mount(tester);
      for (final mode in ['ticker', 'idle', 'lifecycle', 'route']) {
        h.pending = Completer<http.Response>();
        await tester.pump(const Duration(minutes: 15));
        await tester.pump();
        final reads = h.reads;
        final closed = h.closed;
        switch (mode) {
          case 'ticker':
            h.visible.value = false;
          case 'idle':
            h.interaction.setActive(false);
          case 'lifecycle':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          case 'route':
            h.navigator.currentState!.push(
              CupertinoPageRoute<void>(
                builder: (_) =>
                    const CupertinoPageScaffold(child: Text('Other route')),
              ),
            );
        }
        await tester.pumpAndSettle();
        expect(h.closed, greaterThan(closed), reason: mode);
        h.pending!.complete(h.response);
        h.pending = null;
        await tester.pump(const Duration(minutes: 30));
        await tester.pumpAndSettle();
        expect(h.reads, reads, reason: mode);
        expect(banner, findsNothing, reason: mode);
        switch (mode) {
          case 'ticker':
            h.visible.value = true;
          case 'idle':
            h.interaction.setActive(true);
          case 'lifecycle':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          case 'route':
            h.navigator.currentState!.pop();
        }
        await tester.pumpAndSettle();
        expect(h.reads, reads + 1, reason: mode);
        expect(banner, findsOneWidget, reason: mode);
      }
    },
  );

  testWidgets('route changes ignore old responses and do not overlap reads', (
    tester,
  ) async {
    final h = NoticeHarness()..pending = Completer<http.Response>();
    await h.mount(tester);
    expect(h.reads, 1);
    h.location.value = '/media';
    await tester.pump();
    expect(h.reads, 1);
    expect(banner, findsNothing);
    final old = h.pending!;
    h.pending = null;
    h.response = http.Response('', 204);
    old.complete(http.Response(jsonEncode(updates.releaseJson()), 200));
    await tester.pumpAndSettle();
    expect(h.reads, 2);
    expect(banner, findsNothing);
  });

  testWidgets('hidden notice never cancels another page account mutation', (
    tester,
  ) async {
    final h = NoticeHarness();
    await h.mount(tester, login: false);
    h.pendingLogin = Completer<http.Response>();
    final login = h.signIn();
    await tester.pump();
    h.visible.value = false;
    await tester.pump();
    h.pendingLogin!.complete(
      accounts.jsonResponse(accounts.pair(change: false)),
    );
    await login;
    expect(h.account.session, isNotNull);
    expect(h.account.failure, isNull);
    expect(h.reads, 0);
  });

  testWidgets('banner opens PIN gate before updater and nested root can exit', (
    tester,
  ) async {
    final h = NoticeHarness();
    await h.mount(tester, pin: '1234');
    await tester.tap(find.byKey(const ValueKey('client-update-open')));
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.byType(ClientUpdatesScreen), findsNothing);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.byType(ClientUpdatesScreen), findsOneWidget);
    expect(h.api.downloads, 0);
    expect(h.api.installs, 0);
    h.interaction.setActive(false);
    await tester.pump();
    h.interaction.setActive(true);
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.byType(ClientUpdatesScreen), findsNothing);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsGateScreen), findsNothing);
    expect(find.text('Home content'), findsOneWidget);
  });

  testWidgets('320px DeX and large text banner wraps without overflow', (
    tester,
  ) async {
    final h = NoticeHarness();
    await h.mount(tester, size: const Size(320, 650), scale: 2);
    expect(banner, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('client-update-dismiss')));
    await tester.pump();
    expect(banner, findsNothing);
  });

  testWidgets(
    'production router keeps direct updater entry behind settings PIN',
    (tester) async {
      final container = await openApp(tester, pin: '1234');
      final router = container.read(routerProvider);
      router.push('/settings/client-updates');
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byType(ClientUpdatesScreen), findsNothing);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.byType(ClientUpdatesScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/');
      expect(find.byType(SettingsGateScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
