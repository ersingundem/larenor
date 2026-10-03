import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_scope/presentation/server_home_profiles_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_home_registry.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final _now = DateTime.utc(2026, 10, 3, 12);

String _hex(int value) => value.toRadixString(16).padLeft(32, '0');

ServerSession _session(int index) => ServerSession(
  endpoint: ServerEndpoint('https://core-$index.example'),
  accessToken: 'synthetic_access_${index.toString().padLeft(24, '0')}',
  refreshToken: 'synthetic_refresh_${index.toString().padLeft(24, '0')}',
  expiresAt: _now.add(const Duration(hours: 1)),
  user: ServerUser(
    id: _hex(1000 + index),
    username: 'profile-$index',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': _hex(2000 + index),
    'homeId': _hex(3000 + index),
  }),
  sessionFamilyId: _hex(4000 + index),
);

ServerHomeRegistry _fullRegistry({String? activeProfileId}) {
  final profiles = List<ServerHomeProfile>.generate(
    maxServerHomeProfiles,
    (index) => ServerHomeProfile(
      profileId: _hex(index + 1),
      label: 'Home ${index + 1}',
      session: _session(index + 1),
    ),
  );
  return ServerHomeRegistry(
    activeProfileId: activeProfileId ?? profiles.first.profileId,
    profiles: profiles,
  );
}

final class _CountingStore
    implements ServerSessionPersistence, ServerHomeRegistryPersistence {
  _CountingStore(this.delegate);

  final SecureServerSessionStore delegate;
  int writes = 0;

  @override
  Future<ServerSession?> read() => delegate.read();

  @override
  Future<ServerHomeRegistry> readRegistry() => delegate.readRegistry();

  @override
  Future<void> write(ServerSession? session) {
    writes++;
    return delegate.write(session);
  }

  @override
  Future<void> writeRegistry(ServerHomeRegistry registry) {
    writes++;
    return delegate.writeRegistry(registry);
  }
}

final class _ApiCounters {
  int me = 0;
  int context = 0;
  int login = 0;
  int close = 0;
}

final class _Api extends LarenorServerApi {
  _Api(ServerEndpoint endpoint, this.session, this.counters)
    : super(endpoint: endpoint);

  final ServerSession session;
  final _ApiCounters counters;

  @override
  Future<ServerUser> me(String accessToken) async {
    counters.me++;
    return session.user;
  }

  @override
  Future<ServerContext> context(String accessToken) async {
    counters.context++;
    return session.context!;
  }

  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    counters.login++;
    return session;
  }

  @override
  void close() {
    counters.close++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'sixteen profiles disable add and controller preserves the active authority',
    (tester) async {
      final registry = _fullRegistry();
      FlutterSecureStorage.setMockInitialValues({
        SecureServerSessionStore.key: registry.encode(),
      });
      final store = _CountingStore(SecureServerSessionStore());
      final counters = _ApiCounters();
      final active = registry.activeProfile!.session;
      final account = ServerAccountController(
        store: store,
        apiFactory: (endpoint) => _Api(endpoint, active, counters),
        clock: () => _now,
      );
      addTearDown(account.dispose);
      await account.initialize();
      expect(account.failure, isNull);
      expect(account.profiles, hasLength(maxServerHomeProfiles));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(account),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ServerHomeProfilesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final add = tester.widget<CupertinoButton>(
        find.byKey(const ValueKey('server-home-add')),
      );
      expect(add.onPressed, isNull);

      final beforeSession = account.session;
      final beforeProfile = account.activeProfileId;
      final beforeProfiles = account.profiles;
      final beforeGeneration = account.generation;
      final beforeWrites = store.writes;
      final beforeMe = counters.me;
      final beforeContext = counters.context;
      final beforeLogin = counters.login;
      final beforeClose = counters.close;

      await account.beginAddProfile();

      expect(account.failure, 'profile_limit');
      expect(account.session, same(beforeSession));
      expect(account.activeProfileId, beforeProfile);
      expect(account.profiles, orderedEquals(beforeProfiles));
      expect(account.generation, beforeGeneration);
      expect(account.working, isFalse);
      expect(store.writes, beforeWrites);
      expect(counters.me, beforeMe);
      expect(counters.context, beforeContext);
      expect(counters.login, beforeLogin);
      expect(counters.close, beforeClose);
    },
  );

  test(
    'secure registry rejects profile seventeen without replacing bytes',
    () async {
      final populated = _fullRegistry();
      final registry = ServerHomeRegistry(
        activeProfileId: null,
        profiles: populated.profiles,
      );
      FlutterSecureStorage.setMockInitialValues({
        SecureServerSessionStore.key: registry.encode(),
      });
      final storage = const FlutterSecureStorage();
      final store = SecureServerSessionStore(profileId: () => 'f' * 32);
      final before = await storage.read(key: SecureServerSessionStore.key);

      await expectLater(
        store.write(_session(maxServerHomeProfiles + 1)),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'profile_limit',
          ),
        ),
      );

      expect(await storage.read(key: SecureServerSessionStore.key), before);
      expect((await store.readRegistry()).profiles, hasLength(16));
      expect((await store.readRegistry()).activeProfileId, isNull);
    },
  );
}
