import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/app.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_session_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/client_updates/data/client_update_api.dart';
import 'package:larenor/features/client_updates/providers/client_update_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/data/screen_policy_controller.dart';
import 'package:larenor/features/settings/presentation/screen_policy_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/home_scope_fixture.dart'
    show SourceMemory, ScopePower, flush;
import '../server/server_connection_screen_test.dart' show Store;

Map<String, dynamic> contract() =>
    jsonDecode(File('contracts/home-resources.v1.json').readAsStringSync())
        as Map<String, dynamic>;

class ResourceHarness {
  final fixture = contract();
  final source = SourceMemory(HomeSource.verifiedCore);
  final store = Store();
  final power = ScopePower();
  final window = StreamController<WindowPolicySnapshot>.broadcast();
  WindowPolicySnapshot currentWindow = const WindowPolicySnapshot(
    supported: true,
    isResumed: true,
    hasWindowFocus: true,
    reason: WindowRestrictionReason.none,
  );
  DateTime now = DateTime.now();
  int haReads = 0, authPosts = 0, refreshes = 0, resourceReads = 0, closed = 0;
  int status = 200;
  Object? Function(http.Request)? resourceResponse;
  String userId = '9' * 32;
  late Object? response = fixture['memberList'];
  late Object? contextResponse = fixture['context'];
  Completer<http.Response>? pending;
  Completer<http.Response>? pendingContext;
  final requests = <http.Request>[];
  Map<String, Object?> get user => {
    'id': userId,
    'username': 'Fixture',
    'role': 'member',
    'mustChangePassword': false,
  };
  http.Response json(Object? value, [int code = 200]) => http.Response(
    jsonEncode(value),
    code,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/auth/login') ||
        request.url.path.endsWith('/auth/refresh')) {
      authPosts++;
      if (request.url.path.endsWith('/auth/refresh')) refreshes++;
      return json({
        'accessToken': (refreshes.isEven ? 'a' : 'c') * 43,
        'refreshToken': 'b' * 43,
        'expiresIn': 3600,
        'user': user,
      });
    }
    if (request.url.path.endsWith('/auth/me')) return json({'user': user});
    if (request.url.path.endsWith('/context'))
      return pendingContext?.future ?? json(contextResponse);
    if (request.url.path.contains('/home-resources/')) {
      resourceReads++;
      requests.add(request);
      return pending?.future ??
          json(
            resourceResponse == null ? response : resourceResponse!(request),
            status,
          );
    }
    if (request.url.path.endsWith('/auth/logout'))
      return http.Response('', 204);
    throw StateError('Unexpected synthetic route');
  }

  late final account = ServerAccountController(
    store: store,
    apiFactory: (endpoint) => LarenorServerApi(
      endpoint: endpoint,
      client: MockClient(handle),
      clock: () => now,
    ),
    clock: () => now,
  );
  ProviderContainer runtime(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(LarenorApp)),
    listen: false,
  );
  HomeSessionController home(WidgetTester tester) =>
      runtime(tester).read(homeSessionControllerProvider)!;
  GoRouter router(WidgetTester tester) => runtime(tester).read(routerProvider);
  Future<void> signIn() => account.signIn(
    baseUrl: 'https://synthetic.invalid',
    username: 'fixture',
    password: 'synthetic',
    deviceName: 'test',
  );
  Future<void> mount(
    WidgetTester tester, {
    String locale = 'en',
    double width = 600,
    double scale = 1,
    String? pin,
    Map<String, Object> preferences = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'enabled_services_migrated': true,
      ...preferences,
    });
    FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    tester.platformDispatcher.localesTestValue = [Locale(locale)];
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    window.stream.listen((value) => currentWindow = value);
    await tester.pumpWidget(
      ConfigurationScope(
        child: ProviderScope(
          overrides: [
            homeSourceStoreProvider.overrideWithValue(source),
            serverAccountControllerProvider.overrideWithValue(account),
          ],
          child: HomeSessionScope(
            runtimeOverrides: [
              homeResourcesApiFactoryProvider.overrideWithValue(
                (endpoint) => LarenorServerApi(
                  endpoint: endpoint,
                  client: TrackedClient(handle, () => closed++),
                  clock: () => now,
                ),
              ),
              homeResourcesClockProvider.overrideWithValue(() => now),
              connectionConfigProvider.overrideWith(() => BlockHa(this)),
              haRestClientFactoryProvider.overrideWithValue((_, _) {
                haReads++;
                throw StateError('Forbidden HA REST');
              }),
              haWebSocketClientFactoryProvider.overrideWithValue((_, _) {
                haReads++;
                throw StateError('Forbidden HA WS');
              }),
              clientUpdateApiProvider.overrideWithValue(
                AndroidClientUpdateApi(isAndroid: false),
              ),
              screenPolicyControllerProvider.overrideWithValue(
                ScreenPolicyController(power),
              ),
              windowPolicySnapshotProvider.overrideWith((_) async* {
                yield currentWindow;
                yield* window.stream;
              }),
            ],
          ),
        ),
      ),
    );
    window.add(
      const WindowPolicySnapshot(
        supported: true,
        isResumed: true,
        hasWindowFocus: true,
        reason: WindowRestrictionReason.none,
      ),
    );
    await flush(tester);
    addTearDown(() async {
      if (pending?.isCompleted == false)
        pending!.complete(json(fixture['memberList']));
      pending = null;
      if (pendingContext?.isCompleted == false)
        pendingContext!.complete(json(contextResponse));
      pendingContext = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
      account.dispose();
      await window.close();
    });
  }
}

class BlockHa extends ConnectionConfig {
  BlockHa(this.harness);
  final ResourceHarness harness;
  @override
  Future<Never> build() async {
    harness.haReads++;
    throw StateError('Forbidden HA connection');
  }
}

class TrackedClient extends MockClient {
  TrackedClient(super.fn, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}
