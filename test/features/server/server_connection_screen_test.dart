import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/features/server/presentation/server_vault_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/client_updates/presentation/client_updates_screen.dart';

ServerSession session({
  bool requiredChange = false,
  ServerRole role = ServerRole.admin,
}) => ServerSession(
  endpoint: ServerEndpoint('https://server.example'),
  accessToken: 'synthetic_access_token_123',
  refreshToken: 'synthetic_refresh_token_123',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  user: ServerUser(
    id: 'one',
    username: 'Fixture account',
    role: role,
    mustChangePassword: requiredChange,
  ),
);

class Store implements ServerSessionPersistence {
  ServerSession? value;
  int reads = 0;
  @override
  Future<ServerSession?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(ServerSession? session) async {
    value = session;
  }
}

class Api extends LarenorServerApi {
  Api()
    : super(
        endpoint: ServerEndpoint('https://server.example'),
        client: MockClient((_) async => http.Response('{}', 500)),
      );
  int logins = 0, changes = 0, logouts = 0, meReads = 0;
  bool requireChange = true, offline = false;
  ServerRole role = ServerRole.admin;
  Completer<ServerSession>? pendingLogin;
  int contextReads = 0;
  String? contextFailure;
  Completer<ServerContext>? pendingContext;
  @override
  Future<ServerContext> context(String accessToken) async {
    contextReads++;
    if (contextFailure != null) throw LarenorServerException(contextFailure!);
    return pendingContext == null
        ? ServerContext.fromJson({
            'schemaVersion': 1,
            'coreId': 'a' * 32,
            'homeId': 'b' * 32,
          })
        : pendingContext!.future;
  }

  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    logins++;
    return pendingLogin == null
        ? session(requiredChange: requireChange)
        : pendingLogin!.future;
  }

  @override
  Future<ServerUser> me(String token) async {
    meReads++;
    if (offline) throw const LarenorServerException('connection_failed');
    return session(requiredChange: requireChange, role: role).user;
  }

  @override
  Future<ServerSession> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    changes++;
    requireChange = false;
    return session();
  }

  @override
  Future<void> logout(ServerSession session) async {
    logouts++;
  }
}

Future<void> mount(
  WidgetTester tester,
  ServerAccountController account, {
  bool fresh = false,
  String? pin,
  double width = 600,
  double scale = 1,
  String language = 'en',
  AppInteractionController? interaction,
  ValueNotifier<bool>? visible,
}) async {
  FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [serverAccountControllerProvider.overrideWithValue(account)],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: interaction == null
              ? child!
              : AppInteractionScope(controller: interaction, child: child!),
        ),
        home: visible == null
            ? ServerConnectionScreen(freshInstall: fresh)
            : ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, value, child) =>
                    TickerMode(enabled: value, child: child!),
                child: ServerConnectionScreen(freshInstall: fresh),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    account.dispose();
  });
}

Future<void> tap(WidgetTester tester, String key) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> loginFields(WidgetTester tester) async {
  for (final entry in {
    'server-url': 'https://server.example',
    'server-username': 'fixture',
    'server-password': 'Synthetic initial password',
  }.entries) {
    await tester.enterText(find.byKey(ValueKey(entry.key)), entry.value);
  }
}

Future<void> background(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

Future<void> resume(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

void main() {
  for (final language in ['en', 'tr']) {
    testWidgets(
      'password success then real context 404 keeps tokens and offers GET-only recovery ($language tablet 2x)',
      (tester) async {
        final store = Store();
        final initial = session(requiredChange: true);
        final changed = ServerSession(
          endpoint: initial.endpoint,
          accessToken: 'synthetic_changed_access_123',
          refreshToken: 'synthetic_changed_refresh_123',
          expiresAt: initial.expiresAt,
          user: session().user,
        );
        final calls = <String>[];
        var contextAvailable = false;
        http.Response pair(ServerSession value) => http.Response(
          jsonEncode({
            'accessToken': value.accessToken,
            'refreshToken': value.refreshToken,
            'expiresIn': 3600,
            'user': value.user.toJson(),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
        final api = LarenorServerApi(
          endpoint: initial.endpoint,
          client: MockClient((request) async {
            calls.add('${request.method} ${request.url.path}');
            switch (request.url.path) {
              case '/api/v1/auth/login':
                return pair(initial);
              case '/api/v1/auth/password':
                expect(store.value?.authMutationPending, isTrue);
                expect(
                  request.headers['authorization'],
                  'Bearer ${initial.accessToken}',
                );
                return pair(changed);
              case '/api/v1/context':
                expect(request.method, 'GET');
                expect(
                  request.headers['authorization'],
                  'Bearer ${changed.accessToken}',
                );
                expect(store.value?.refreshToken, changed.refreshToken);
                expect(store.value?.authMutationPending, isFalse);
                if (!contextAvailable) {
                  return http.Response(
                    '<html>synthetic-private-proxy-content</html>',
                    404,
                  );
                }
                return http.Response(
                  jsonEncode({
                    'schemaVersion': 1,
                    'coreId': 'a' * 32,
                    'homeId': 'b' * 32,
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              default:
                fail('Unexpected request in synthetic account flow');
            }
          }),
        );
        final account = ServerAccountController(
          store: store,
          apiFactory: (_) => api,
        );
        await mount(tester, account, width: 900, scale: 2, language: language);
        await loginFields(tester);
        await tap(tester, 'server-sign-in');
        await tester.pumpAndSettle();
        expect(calls, ['POST /api/v1/auth/login']);
        expect(account.session?.user.mustChangePassword, isTrue);
        expect(account.context, isNull);
        expect(find.byKey(const ValueKey('server-admin')), findsNothing);
        for (final entry in {
          'server-current-password': 'Synthetic initial password',
          'server-new-password': 'A new synthetic password',
          'server-confirm-password': 'A new synthetic password',
        }.entries) {
          await tester.enterText(find.byKey(ValueKey(entry.key)), entry.value);
        }
        await tap(tester, 'server-change-password');
        await tester.pumpAndSettle();
        final explanation = language == 'en'
            ? 'Home verification is unavailable at this address. Check the Server address or update Larenor Server, then retry.'
            : 'Bu adreste ev doğrulaması kullanılamıyor. Server adresini kontrol edin veya Larenor Server’ı güncelleyin, ardından yeniden deneyin.';
        expect(find.text(explanation), findsOneWidget);
        await tester.ensureVisible(find.text(explanation));
        await tester.pumpAndSettle();
        expect(find.text(explanation).hitTestable(), findsOneWidget);
        expect(account.failure, 'context_endpoint_unavailable');
        expect(account.hasPendingContext, isTrue);
        expect(account.session, isNull);
        expect(store.value?.refreshToken, changed.refreshToken);
        expect(store.value?.context, isNull);
        expect(find.byKey(const ValueKey('server-admin')), findsNothing);
        expect(
          find.byKey(const ValueKey('server-current-password')),
          findsNothing,
        );
        expect(find.textContaining('synthetic_changed_'), findsNothing);
        expect(
          find.textContaining('synthetic-private-proxy-content'),
          findsNothing,
        );
        expect(
          find.textContaining('context_endpoint_unavailable'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        contextAvailable = true;
        await tap(tester, 'server-context-retry');
        await tester.pumpAndSettle();
        expect(calls, [
          'POST /api/v1/auth/login',
          'POST /api/v1/auth/password',
          'GET /api/v1/context',
          'GET /api/v1/context',
        ]);
        expect(account.context?.coreId, 'a' * 32);
        expect(store.value?.refreshToken, changed.refreshToken);
        expect(find.text(explanation), findsNothing);
        expect(find.byKey(const ValueKey('server-admin')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'tr']) {
    testWidgets(
      'pending context has a guarded GET-only recovery at tablet 2x ($language)',
      (tester) async {
        final store = Store()..value = session();
        final api = Api()
          ..requireChange = false
          ..contextFailure = 'timeout';
        final account = ServerAccountController(
          store: store,
          apiFactory: (_) => api,
        );
        await mount(tester, account, width: 900, scale: 2, language: language);
        expect(account.hasPendingContext, isTrue);
        expect(
          find.byKey(const ValueKey('server-context-retry')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('server-password')), findsNothing);
        expect(find.byKey(const ValueKey('server-admin')), findsNothing);
        expect(find.byKey(const ValueKey('server-vault')), findsNothing);
        expect(tester.takeException(), isNull);
        api.contextFailure = null;
        await tap(tester, 'server-context-retry');
        expect(api.contextReads, 2);
        expect(api.logins, 0);
        expect(api.changes, 0);
        expect(account.context, isNotNull);
        expect(
          find.byKey(const ValueKey('server-context-retry')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('server-admin')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'background cancels only the context read and late success cannot unlock the account',
    (tester) async {
      final store = Store()..value = session();
      final api = Api()
        ..requireChange = false
        ..contextFailure = 'timeout';
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account);
      api.contextFailure = null;
      api.pendingContext = Completer<ServerContext>();
      await tap(tester, 'server-context-retry');
      await background(tester);
      api.pendingContext!.complete(
        ServerContext.fromJson({
          'schemaVersion': 1,
          'coreId': 'a' * 32,
          'homeId': 'b' * 32,
        }),
      );
      await tester.pump();
      expect(account.context, isNull);
      expect(account.hasPendingContext, isTrue);
      expect(store.value, isNotNull);
      await resume(tester);
      expect(api.contextReads, 2);
      api.pendingContext = null;
      await tap(tester, 'server-context-retry');
      expect(account.context, isNotNull);
      expect(api.contextReads, 3);
      expect(api.logins, 0);
    },
  );

  testWidgets('member vault/update access has no administrator entry', (
    tester,
  ) async {
    final api = Api()
      ..requireChange = false
      ..role = ServerRole.member;
    final store = Store()..value = session(role: ServerRole.member);
    final account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
    );
    await mount(tester, account);
    expect(find.byKey(const ValueKey('server-admin')), findsNothing);
    expect(find.byKey(const ValueKey('server-vault')), findsOneWidget);
    expect(find.byKey(const ValueKey('server-client-updates')), findsOneWidget);
  });

  testWidgets(
    'confirmed server account opens its real vault through guarded entry',
    (tester) async {
      final api = Api()..requireChange = false;
      final store = Store()..value = session();
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account, fresh: true);
      expect(find.byKey(const ValueKey('server-vault')), findsOneWidget);
      await tap(tester, 'server-vault');
      await tester.pumpAndSettle();
      expect(find.byType(ServerVaultScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('server-vault-review')), findsOneWidget);
    },
  );

  testWidgets('Turkish form uses localized labels', (tester) async {
    final account = ServerAccountController(
      store: Store(),
      apiFactory: (_) => Api(),
    );
    await mount(tester, account, language: 'tr');
    expect(find.text('Sunucu adresi'), findsOneWidget);
    expect(find.text('Kullanıcı adı'), findsOneWidget);
    expect(find.text('Giriş yap'), findsOneWidget);
  });

  testWidgets('old update navigation cannot open after server sign-out', (
    tester,
  ) async {
    final store = Store()..value = session(),
        api = Api()..requireChange = false;
    final account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
    );
    await mount(tester, account);
    final open = tester
        .widget<CupertinoListTile>(
          find.byKey(const ValueKey('server-client-updates')),
        )
        .onTap!;
    await account.signOut();
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();
    expect(find.byType(ClientUpdatesScreen), findsNothing);
  });
  testWidgets('new Settings PIN cancels pending first-install sign-in', (
    tester,
  ) async {
    final store = Store(), api = Api()..pendingLogin = Completer();
    final account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
    );
    await mount(tester, account, fresh: true);
    await loginFields(tester);
    await tap(tester, 'server-sign-in');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ServerConnectionScreen)),
    );
    await container.read(pinLockProvider.notifier).setPin('2468');
    await tester.pump();
    api.pendingLogin!.complete(session());
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(
      find.text('Open Settings to manage this server account.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'account replacement clears password drafts and invalidates old submit',
    (tester) async {
      final store = Store()..value = session(),
          api = Api()..requireChange = false;
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account);
      await tap(tester, 'server-edit-password');
      for (final key in [
        'server-current-password',
        'server-new-password',
        'server-confirm-password',
      ]) {
        await tester.enterText(
          find.byKey(ValueKey(key)),
          'Synthetic password to clear',
        );
      }
      final old = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('server-change-password')),
          )
          .onPressed!;
      await account.signOut();
      api.requireChange = true;
      await account.signIn(
        baseUrl: 'https://server.example',
        username: 'other',
        password: 'Other synthetic password',
        deviceName: 'fixture',
      );
      await tester.pumpAndSettle();
      old();
      await tester.pump();
      expect(api.changes, 0);
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('server-current-password')),
            )
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets('idle invalidates an already captured login callback', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    final store = Store(), api = Api();
    final account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
    );
    await mount(tester, account, interaction: interaction);
    await loginFields(tester);
    final old = tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('server-sign-in')))
        .onPressed!;
    interaction.setActive(false);
    await tester.pump();
    interaction.setActive(true);
    await tester.pumpAndSettle();
    old();
    await tester.pump();
    expect(api.logins, 0);
  });

  testWidgets(
    'sign-in is explicit; forced change rejects mismatch then exposes verified account',
    (tester) async {
      final store = Store(), api = Api();
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account);
      expect(api.logins, 0);
      await loginFields(tester);
      await tap(tester, 'server-sign-in');
      await tester.pumpAndSettle();
      expect(api.logins, 1);
      expect(
        find.text('Change your initial password to continue.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('server-edit-password')), findsNothing);
      expect(find.byKey(const ValueKey('server-client-updates')), findsNothing);
      expect(find.textContaining('synthetic_access'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('server-current-password')),
        'Synthetic initial password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-new-password')),
        'A new synthetic password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-confirm-password')),
        'Does not match',
      );
      await tap(tester, 'server-change-password');
      expect(api.changes, 0);
      await tester.enterText(
        find.byKey(const ValueKey('server-confirm-password')),
        'A new synthetic password',
      );
      await tap(tester, 'server-change-password');
      await tester.pumpAndSettle();
      expect(api.changes, 1);
      expect(store.value?.user.mustChangePassword, isFalse);
      expect(
        find.byKey(const ValueKey('server-edit-password')),
        findsOneWidget,
      );
      expect(find.text('Your password has been changed.'), findsOneWidget);
      expect(find.text('Administrator'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('server-client-updates')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'duplicate sign-in and background late completion cannot persist a session',
    (tester) async {
      final store = Store(), api = Api()..pendingLogin = Completer();
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account);
      await loginFields(tester);
      final callback = tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('server-sign-in')))
          .onPressed!;
      callback();
      callback();
      await tester.pump();
      expect(api.logins, 1);
      await background(tester);
      api.pendingLogin!.complete(session());
      await tester.pump();
      await resume(tester);
      await tester.pumpAndSettle();
      expect(account.session, isNull);
      expect(store.value, isNull);
      expect(find.text('Fixture account'), findsNothing);
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('server-password')),
            )
            .controller!
            .text,
        isEmpty,
      );
      callback();
      await tester.pump();
      expect(api.logins, 1);
    },
  );

  testWidgets('hidden page cancels sign-in and never restores its password', (
    tester,
  ) async {
    final store = Store(), api = Api()..pendingLogin = Completer();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final account = ServerAccountController(
      store: store,
      apiFactory: (_) => api,
    );
    await mount(tester, account, visible: visible);
    await loginFields(tester);
    await tap(tester, 'server-sign-in');
    visible.value = false;
    await tester.pump();
    api.pendingLogin!.complete(session());
    await tester.pump();
    visible.value = true;
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.text('Fixture account'), findsNothing);
  });

  testWidgets(
    'offline restored session remains unavailable until explicit retry verifies role',
    (tester) async {
      final store = Store()..value = session(),
          api = Api()
            ..requireChange = false
            ..offline = true;
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account);
      expect(store.value, isNotNull);
      expect(find.text('Fixture account'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      api.offline = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture account'), findsOneWidget);
      expect(api.meReads, 2);
    },
  );

  testWidgets(
    'PIN-protected fresh-install route never reads saved server session',
    (tester) async {
      final store = Store()..value = session(), api = Api();
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account, fresh: true, pin: '2468');
      expect(store.reads, 0);
      expect(api.meReads, 0);
      expect(
        find.text('Open Settings to manage this server account.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('server-sign-in')), findsNothing);
    },
  );

  testWidgets(
    'logout confirmation cancels cleanly and stale background confirmation sends nothing',
    (tester) async {
      final store = Store()..value = session(),
          api = Api()..requireChange = false;
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => api,
      );
      await mount(tester, account);
      await tap(tester, 'server-sign-out');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      expect(api.logouts, 0);
      await tap(tester, 'server-sign-out');
      await tester.pumpAndSettle();
      final old = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Sign out of Server'),
          )
          .onPressed!;
      await background(tester);
      await resume(tester);
      old();
      await tester.pumpAndSettle();
      expect(api.logouts, 0);
      expect(account.session, isNotNull);
      await tap(tester, 'server-sign-out');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CupertinoDialogAction, 'Sign out of Server'),
      );
      await tester.pumpAndSettle();
      expect(api.logouts, 1);
      expect(store.value, isNull);
    },
  );

  for (final dimensions in [(320.0, 2.0), (1280.0, 1.6)]) {
    testWidgets(
      'form remains reachable at width ${dimensions.$1} text ${dimensions.$2}',
      (tester) async {
        final account = ServerAccountController(
          store: Store(),
          apiFactory: (_) => Api(),
        );
        await mount(
          tester,
          account,
          width: dimensions.$1,
          scale: dimensions.$2,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-sign-in')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('server-sign-in')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel('Server address'), findsWidgets);
        semantics.dispose();
      },
    );
  }
}
