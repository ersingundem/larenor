import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/client_updates/data/client_release_repository.dart';
import 'package:larenor/features/client_updates/domain/client_update_models.dart';
import 'package:larenor/features/client_updates/presentation/client_updates_screen.dart';
import 'package:larenor/features/client_updates/providers/client_update_providers.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_account_test.dart' as account_fixture;
import 'client_updates_test.dart' as update_fixture;

void main() {
  late update_fixture.FakeApi api;
  late ServerAccountController account;
  late http.Response response;
  late int reads;

  setUp(() {
    api = update_fixture.FakeApi();
    reads = 0;
    response = http.Response(jsonEncode(update_fixture.releaseJson()), 200);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool login = true,
    Size size = const Size(900, 1000),
    double scale = 1,
  }) async {
    // Construct the controller's serial-write Future in this widget test's
    // async zone, not the outer setUp zone.
    account = ServerAccountController(
      store: account_fixture.MemorySessions(),
      clock: () => account_fixture.now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        clock: () => account_fixture.now,
        client: MockClient(
          (request) async => request.url.path.endsWith('/logout')
              ? http.Response('', 204)
              : account_fixture.jsonResponse(
                  account_fixture.pair(change: false),
                ),
        ),
      ),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (login) {
      await account.signIn(
        baseUrl: 'https://server.test',
        username: 'admin',
        password: 'synthetic-password',
        deviceName: 'Test tablet',
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account),
          clientUpdateApiProvider.overrideWithValue(api),
          clientReleaseFactoryProvider.overrideWithValue(
            (source) => ClientReleaseRepository(
              baseUrl: source.baseUrl,
              accessToken: source.accessToken,
              isCurrent: source.isCurrent,
              clientFactory: () => MockClient((request) async {
                expect(request.method, 'GET');
                expect(request.url.path, '/api/v1/client/releases/latest');
                reads++;
                return response;
              }),
            ),
          ),
        ],
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ClientUpdatesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
      await api.events.close();
    });
  }

  Future<void> press(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'checking shows available release without download or installation',
    (tester) async {
      await mount(tester);
      expect(reads, 1);
      expect(find.text('A new Client version is available'), findsOneWidget);
      expect(api.downloads, 0);
      expect(api.installs, 0);
      await press(tester, 'updates-download');
      expect(api.downloads, 1);
      expect(api.installs, 0);
      expect(find.text('Update verified and ready to install'), findsOneWidget);
      await press(tester, 'updates-install');
      expect(api.installs, 1);
      expect(find.textContaining('Android installer opened.'), findsOneWidget);
      expect(find.byKey(const ValueKey('updates-install')), findsNothing);
    },
  );

  testWidgets(
    'signed-out screen cannot read releases or invoke native actions',
    (tester) async {
      await mount(tester, login: false);
      expect(reads, 0);
      expect(find.textContaining('Sign in to Larenor Server'), findsOneWidget);
      expect(api.downloads, 0);
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('updates-check')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('no release and a failed read are distinct', (tester) async {
    response = http.Response('', 204);
    await mount(tester);
    expect(
      find.text('Server has no published Client release yet.'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .join(' | '),
    );
    response = http.Response('synthetic-private-error', 500);
    await press(tester, 'updates-check');
    expect(
      find.text('Server has no published Client release yet.'),
      findsNothing,
    );
    expect(find.textContaining('Could not check or download'), findsOneWidget);
    expect(find.textContaining('synthetic-private-error'), findsNothing);
  });

  testWidgets('wrong signer never presents a download action', (tester) async {
    response = http.Response(
      jsonEncode({
        ...update_fixture.releaseJson(),
        'certificateSha256': 'd' * 64,
      }),
      200,
    );
    await mount(tester);
    expect(find.textContaining('This release cannot update'), findsOneWidget);
    expect(find.byKey(const ValueKey('updates-download')), findsNothing);
    expect(api.downloads, 0);
  });

  testWidgets('permission settings do not automatically download or install', (
    tester,
  ) async {
    api.permission = false;
    await mount(tester);
    await press(tester, 'updates-permission');
    expect(api.settings, 1);
    expect(api.downloads, 0);
    expect(api.installs, 0);
  });

  testWidgets('old install callback cannot act after account logout', (
    tester,
  ) async {
    await mount(tester);
    await press(tester, 'updates-download');
    final action = tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('updates-install')))
        .onPressed!;
    await account.signOut();
    await tester.pumpAndSettle();
    action();
    await tester.pumpAndSettle();
    expect(api.installs, 0);
    expect(find.byKey(const ValueKey('updates-install')), findsNothing);
  });

  testWidgets(
    'background cancels transfer and late result does not enable install',
    (tester) async {
      api.pending = Completer<StagedClientUpdate>();
      await mount(tester);
      final target = find.byKey(const ValueKey('updates-download'));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.downloads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(api.cancels, greaterThan(0));
      api.pending!.complete(api.staged());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('updates-install')), findsNothing);
      expect(api.installs, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow DeX window with large text stays scrollable', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 600), scale: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('updates-download')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(api.downloads, 0);
  });
}
