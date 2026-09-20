import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
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
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

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
    Locale locale = const Locale('en'),
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
              : request.url.path.endsWith('/context')
              ? account_fixture.jsonResponse(account_fixture.contextJson())
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
          locale: locale,
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

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'client updates uses the shared tablet surface $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(
              tester,
              size: Size(width, 1100),
              scale: 2,
              locale: Locale(language),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(ClientUpdatesScreen)),
            );

            expect(find.byType(SettingsSection), findsAtLeastNWidgets(1));
            expect(find.byType(SettingsActionTile), findsAtLeastNWidgets(1));
            final heading = find.byKey(
              const ValueKey('client-updates-status-heading'),
            );
            final headingNode = tester.getSemantics(heading);
            expect(headingNode.label, l10n.clientUpdatesStatus);
            expect(headingNode.flagsCollection.isHeader, isTrue);
            expect(headingNode.flagsCollection.isButton, isFalse);

            final check = find.byKey(const ValueKey('updates-check'));
            final checkNode = tester.getSemantics(check);
            expect(checkNode.label, l10n.clientUpdatesCheck);
            expect(checkNode.flagsCollection.isButton, isTrue);
            expect(checkNode.rect.width, greaterThanOrEqualTo(48));
            expect(checkNode.rect.height, greaterThanOrEqualTo(48));

            final label = find.descendant(
              of: check,
              matching: find.text(l10n.clientUpdatesCheck),
            );
            Focus.of(tester.element(label)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(reads, 2);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'checking shows available release without download or installation',
    (tester) async {
      await mount(tester);
      expect(reads, 1);
      expect(find.text('A new Client version is available'), findsOneWidget);
      expect(find.byKey(const ValueKey('updates-status-card')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('updates-installed-version')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('updates-available-version')),
        findsOneWidget,
      );
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

  testWidgets('retained cancel cannot stop a newer download generation', (
    tester,
  ) async {
    final first = Completer<StagedClientUpdate>();
    api.pending = first;
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('updates-download')));
    await tester.pump();
    final oldCancel = tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('updates-cancel')))
        .onPressed!;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    first.complete(api.staged());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    final second = Completer<StagedClientUpdate>();
    api.pending = second;
    await tester.tap(find.byKey(const ValueKey('updates-download')));
    await tester.pump();
    final cancelsBefore = api.cancels;
    oldCancel();
    await tester.pump();
    expect(api.cancels, cancelsBefore);
    second.complete(api.staged());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updates-install')), findsOneWidget);
  });

  testWidgets('narrow DeX window with large text stays scrollable', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 600), scale: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('updates-download')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(api.downloads, 0);
  });

  testWidgets('update actions keep tablet tap targets at 2x text', (
    tester,
  ) async {
    await mount(tester, size: const Size(600, 900), scale: 2);
    final action = find.byKey(const ValueKey('updates-download'));
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}
