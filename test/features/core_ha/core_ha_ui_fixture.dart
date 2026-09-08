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
import 'package:larenor/features/core_ha/data/core_ha_providers.dart';

import 'core_ha_api_test.dart' show serviceJson;

import 'package:larenor/features/home_resources/data/home_resources_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/data/screen_policy_controller.dart';
import 'package:larenor/features/settings/presentation/screen_policy_runner.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/home_scope_fixture.dart'
    show SourceMemory, ScopePower, flush;
import '../server/server_connection_screen_test.dart' show Store;

Map<String, dynamic> contract() =>
    jsonDecode(File('contracts/home-assistant.v1.json').readAsStringSync())
        as Map<String, dynamic>;

class HaUiHarness {
  HaUiHarness({this.pinStore});
  final PinLockStore? pinStore;
  final f = contract();
  late final fixture = {
    'context': f['context'],
    'memberList': {
      'scope': f['context'],
      'entries': [f['resource']],
      'snapshot': 'a' * 64,
      'nextAfter': null,
    },
  };
  String role = 'admin';
  int snapshotReads = 0, previewCount = 0;
  bool bound = false, uncertainConfirm = false;
  String snapshotStep = 'snapshotOff';
  final adapterRequests = <http.Request>[];
  Completer<http.Response>? pendingSnapshot, pendingConfirm;
  Duration elapsed = Duration.zero;
  final boundary = GlobalKey();
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
  Object? detailRecord;
  String userId = '9' * 32;
  late Object? response = fixture['memberList'];
  late Object? contextResponse = fixture['context'];
  Completer<http.Response>? pending;
  Completer<http.Response>? pendingContext;
  final requests = <http.Request>[];
  Map<String, Object?> get user => {
    'id': userId,
    'username': 'Fixture',
    'role': role,
    'mustChangePassword': false,
  };
  http.Response json(Object? value, [int code = 200]) => code == 204
      ? http.Response('', 204)
      : http.Response(
          jsonEncode(value),
          code,
          headers: {'content-type': 'application/json'},
        );
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.contains('/home-assistant/') ||
        request.url.path.endsWith('/admin/services')) {
      adapterRequests.add(request);
      expectSync(
        request.headers['authorization'],
        refreshes.isEven ? 'Bearer ${'a' * 43}' : 'Bearer ${'c' * 43}',
      );
      if (request.url.path.endsWith('/admin/services')) {
        return json({
          'services': [
            {...serviceJson(), 'id': f['preview']['body']['serviceId']},
          ],
        });
      }
      expectSync(
        request.url.path.contains(
          '/${f['context']['coreId']}/${f['context']['homeId']}/resources/${f['resource']['ref']['id']}',
        ),
        isTrue,
      );
      if (request.url.path.endsWith('/snapshot')) {
        snapshotReads++;
        return pendingSnapshot?.future ??
            json(f[snapshotStep]['response'], f[snapshotStep]['status'] as int);
      }
      if (request.url.path.endsWith('/commands')) {
        final requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        final response = jsonDecode(
          jsonEncode(f['commandAccepted']['response']),
        ) as Map<String, dynamic>;
        final receipt = response['receipt'] as Map<String, dynamic>;
        receipt['requestId'] = requestBody['requestId'];
        receipt['action'] = requestBody['action'];
        if (requestBody['action'] == 'turn_on') {
          (receipt['observedProjection'] as Map<String, dynamic>)['state'] =
              'on';
        }
        return json(response, 202);
      }
      if (request.url.path.contains('/commands/')) {
        return json(f['commandResult']['response']);
      }
      expectSync(role, 'admin');
      final path = request.url.path;
      final step = path.endsWith('/binding')
          ? (bound ? 'binding' : 'unbound')
          : path.endsWith('/binding-preview')
          ? (++previewCount == 1 ? 'preview' : 'secondPreview')
          : path.endsWith('/binding-confirm')
          ? 'confirm'
          : 'cancel';
      if (step == 'confirm') {
        bound = true;
        if (pendingConfirm != null) return pendingConfirm!.future;
        if (uncertainConfirm) {
          return json({
            'error': {'code': 'server_error'},
          }, 503);
        }
        final key = previewCount == 1 ? 'preview' : 'secondPreview';
        return json({'binding': f[key]['response']['preview']['binding']}, 201);
      }
      return json(f[step]['response'], f[step]['status'] as int);
    }

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
    if (request.url.path.endsWith('/context')) {
      return pendingContext?.future ?? json(contextResponse);
    }
    if (request.url.path.contains('/home-resources/')) {
      resourceReads++;
      requests.add(request);
      return pending?.future ??
          json(
            request.url.path.endsWith(f['resource']['ref']['id'] as String)
                ? {'record': detailRecord ?? f['resource']}
                : resourceResponse != null
                ? resourceResponse!(request)
                : response,
            status,
          );
    }
    if (request.url.path.endsWith('/auth/logout')) {
      return http.Response('', 204);
    }
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
    window.stream.listen(
      (value) => currentWindow = value,
      onError: (Object _) {},
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: ConfigurationScope(
          child: ProviderScope(
            overrides: [
              homeSourceStoreProvider.overrideWithValue(source),
              serverAccountControllerProvider.overrideWithValue(account),
            ],
            child: HomeSessionScope(
              runtimeOverrides: [
                if (pinStore != null)
                  pinLockStoreProvider.overrideWith((_) => pinStore!),
                homeResourcesApiFactoryProvider.overrideWithValue(
                  (endpoint) => LarenorServerApi(
                    endpoint: endpoint,
                    client: TrackedClient(handle, () => closed++),
                    clock: () => now,
                  ),
                ),
                homeResourcesClockProvider.overrideWithValue(() => now),
                coreHaClockProvider.overrideWithValue(() => now),
                coreHaMonotonicProvider.overrideWithValue(() => elapsed),
                coreHaRequestIdProvider.overrideWithValue(() => '7' * 32),
                coreHaApiFactoryProvider.overrideWithValue(
                  (endpoint) => LarenorServerApi(
                    endpoint: endpoint,
                    client: TrackedClient(handle, () => closed++),
                    clock: () => now,
                  ),
                ),
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
      if (pending?.isCompleted == false) {
        pending!.complete(json(fixture['memberList']));
      }
      pending = null;
      if (pendingContext?.isCompleted == false) {
        pendingContext!.complete(json(contextResponse));
      }
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
  final HaUiHarness harness;
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
