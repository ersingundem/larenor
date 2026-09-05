import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/app.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_session_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/client_updates/data/client_update_api.dart';
import 'package:larenor/features/client_updates/providers/client_update_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/data/screen_policy_controller.dart';
import 'package:larenor/features/settings/presentation/screen_policy_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/server/server_connection_screen_test.dart' as server;

class SourceMemory implements HomeSourcePersistence {
  SourceMemory(this.value);
  HomeSource value;
  int reads = 0, writes = 0;
  bool readFails = false, writeFails = false;
  Completer<void>? pendingWrite;
  @override
  Future<HomeSource> read() async {
    reads++;
    if (readFails) throw const HomeSourceException('source_read_failed');
    return value;
  }

  @override
  Future<void> write(HomeSource source) async {
    writes++;
    await pendingWrite?.future;
    if (writeFails) throw const HomeSourceException('source_write_failed');
    value = source;
  }
}

class ScopeApi extends server.Api {
  String coreId = 'a' * 32, homeId = 'b' * 32, userId = 'one';
  int refreshes = 0;
  ServerContext get identity => ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
  });
  ServerSession fresh() => server
      .session(requiredChange: requireChange)
      .withUser(
        ServerUser(
          id: userId,
          username: 'Fixture account',
          role: ServerRole.admin,
          mustChangePassword: requireChange,
        ),
      );
  @override
  Future<ServerContext> context(String accessToken) async {
    contextReads++;
    if (contextFailure != null) throw LarenorServerException(contextFailure!);
    return pendingContext == null ? identity : pendingContext!.future;
  }

  @override
  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    logins++;
    return fresh();
  }

  @override
  Future<ServerSession> refresh(String token) async {
    refreshes++;
    return fresh();
  }
}

class NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async =>
      throw UnsupportedError('Synthetic discovery unavailable');
}

class Connection extends ConnectionConfig {
  Connection(this.owner);
  final ScopeHarness owner;
  @override
  Future<HaConnectionConfig?> build() async {
    owner.connectionReads++;
    return owner.localHa
        ? const HaConnectionConfig(
            baseUrl: 'https://ha.example.test',
            token: 'synthetic',
          )
        : null;
  }
}

class ScopeRest extends HaRestClient {
  ScopeRest()
    : super(
        baseUrl: 'https://ha.example.test',
        token: 'synthetic',
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      );
  final states = Completer<List<HaEntity>>();
  bool disposed = false;
  int reads = 0;
  @override
  Future<List<HaEntity>> getStates() {
    reads++;
    return states.future;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class ScopeSocket extends HaWebSocketClient {
  ScopeSocket() : super(baseUrl: 'https://ha.example.test', token: 'synthetic');
  final events = StreamController<HaEntityChange>.broadcast();
  bool disposed = false;
  @override
  void connect() {}
  @override
  Stream<HaConnectionStatus> get status =>
      Stream.value(HaConnectionStatus.connected);
  @override
  Stream<HaEntityChange> get entityChanges => events.stream;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class ScopePower implements ScreenPolicyPlatform {
  bool awake = false;
  @override
  Future<void> keepAwake(bool value) async {
    awake = value;
  }

  @override
  Future<void> dim() async {}
  @override
  Future<void> resetBrightness() async {}
}

class ScopeHarness {
  ScopeHarness(HomeSource initial) : source = SourceMemory(initial);
  final SourceMemory source;
  final api = ScopeApi()..requireChange = false;
  final store = server.Store();
  DateTime now = DateTime.now();
  late final account = ServerAccountController(
    store: store,
    apiFactory: (_) => api,
    clock: () => now,
  );
  final rest = ScopeRest();
  final socket = ScopeSocket();
  final power = ScopePower();
  int connectionReads = 0, ambientReads = 0;
  bool ambientPhotos = false;
  bool localHa = false;
  ProviderContainer runtime(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(LarenorApp)),
    listen: false,
  );
  HomeSessionController home(WidgetTester tester) =>
      runtime(tester).read(homeSessionControllerProvider)!;
  GoRouter router(WidgetTester tester) => runtime(tester).read(routerProvider);

  Future<void> mount(
    WidgetTester tester, {
    String? pin,
    String locale = 'en',
    double width = 600,
    double scale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({'enabled_services_migrated': true,
      if (ambientPhotos) AmbientSettings.preferenceKey: const AmbientSettings(photosEnabled: true).encode(),
    });
    FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    tester.platformDispatcher.localeTestValue = Locale(locale);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ConfigurationScope(
        child: ProviderScope(
          overrides: [
            homeSourceStoreProvider.overrideWithValue(source),
            serverAccountControllerProvider.overrideWithValue(account),
          ],
          child: HomeSessionScope(
            runtimeOverrides: [
              connectionConfigProvider.overrideWith(() => Connection(this)),
              haDiscoveryFactoryProvider.overrideWithValue(NoDiscovery.new),
            ambientLibraryProvider.overrideWith((_) async { ambientReads++; return const []; }),
              clientUpdateApiProvider.overrideWithValue(
                AndroidClientUpdateApi(isAndroid: false),
              ),
              haRestClientFactoryProvider.overrideWithValue((_, _) => rest),
              haWebSocketClientFactoryProvider.overrideWithValue(
                (_, _) => socket,
              ),
              screenPolicyControllerProvider.overrideWithValue(
                ScreenPolicyController(power),
              ),
              windowPolicySnapshotProvider.overrideWith(
                (_) => Stream.value(
                  const WindowPolicySnapshot(
                    supported: true,
                    isResumed: true,
                    hasWindowFocus: true,
                    reason: WindowRestrictionReason.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await flush(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      // ConnectScreen has a bounded discovery delay; allow its mounted guard to finish.
      await tester.pump(const Duration(seconds: 7));
      await flush(tester);
      account.dispose();
      await socket.events.close();
    });
  }

  Future<void> signIn() => account.signIn(
    baseUrl: 'https://server.example',
    username: 'fixture',
    password: 'synthetic',
    deviceName: 'fixture',
  );
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> press(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await flush(tester);
}

Future<void> loginOnScreen(WidgetTester tester) async {
  for (final field in {
    'server-url': 'https://server.example',
    'server-username': 'fixture',
    'server-password': 'synthetic',
  }.entries) {
    await tester.enterText(find.byKey(ValueKey(field.key)), field.value);
  }
  await press(tester, 'server-sign-in');
}
