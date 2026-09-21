import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/camera_search/presentation/camera_search_route.dart';
import 'package:larenor/features/camera_search/presentation/camera_search_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const coreId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const homeId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const cameraId = 'dddddddddddddddddddddddddddddddd';

final class _Source implements HomeSourcePersistence {
  HomeSource value = HomeSource.verifiedCore;
  @override
  Future<HomeSource> read() async => value;
  @override
  Future<void> write(HomeSource source) async => value = source;
}

final class _Sessions implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> _page() => {
  'schemaVersion': 1,
  'indexRevision': 7,
  'mode': 'local_metadata',
  'status': 'degraded',
  'degradedReason': 'semantic_provider_unavailable',
  'results': [
    {
      'schemaVersion': 1,
      'startMs': 1788609600000,
      'endMs': 1788609660000,
      'summary': 'A parcel was left by the door',
      'matchedTerms': ['parcel'],
      'evidence': {
        'schemaVersion': 1,
        'kind': 'camera_evidence',
        'coreId': coreId,
        'homeId': homeId,
        'cameraId': cameraId,
        'clipId': 'e' * 32,
        'eventId': 'f' * 32,
        'captureRevision': 4,
        'indexRevision': 7,
        'capturedAtMs': 1788609610000,
      },
    },
  ],
  'nextCursor': null,
};

final class _Harness {
  _Harness({this.pendingSearch});
  final Completer<http.Response>? pendingSearch;
  final source = _Source();
  final requests = <http.Request>[];
  late final client = MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('/auth/login')) {
      return _json({
        'accessToken': 'x' * 43,
        'refreshToken': 'y' * 43,
        'expiresIn': 3600,
        'user': {
          'id': 'c' * 32,
          'username': 'fixture',
          'role': 'member',
          'mustChangePassword': false,
        },
      });
    }
    if (request.url.path.endsWith('/context') &&
        !request.url.path.contains('/camera-search/')) {
      return _json({'schemaVersion': 1, 'coreId': coreId, 'homeId': homeId});
    }
    if (request.method == 'GET' &&
        request.url.path.endsWith('/camera-search/$coreId/$homeId/context')) {
      return _json({
        'schemaVersion': 1,
        'coreId': coreId,
        'homeId': homeId,
        'indexRevision': 7,
        'cameraIds': [cameraId],
        'maxWindowDays': 31,
      });
    }
    if (request.method == 'POST' && request.url.path.endsWith('/search')) {
      return pendingSearch?.future ?? _json(_page());
    }
    return _json({
      'error': {'code': 'not_found'},
    }, 404);
  });
  late final account = ServerAccountController(
    store: _Sessions(),
    apiFactory: (endpoint) =>
        LarenorServerApi(endpoint: endpoint, client: client),
    clock: () => DateTime.utc(2026, 9, 5, 12),
  );
  late final home = HomeSessionController(store: source, account: account);

  Future<void> initialize() async {
    await account.signIn(
      baseUrl: 'https://core.invalid',
      username: 'fixture',
      password: 'password',
      deviceName: 'tablet',
    );
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
  }

  Future<void> mount(WidgetTester tester, {String language = 'en'}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeSessionControllerProvider.overrideWithValue(home),
          windowPolicySnapshotProvider.overrideWith((_) async* {
            yield const WindowPolicySnapshot(
              supported: false,
              isResumed: true,
              hasWindowFocus: true,
              reason: WindowRestrictionReason.unsupported,
            );
          }),
        ],
        child: AppInteractionScope(
          controller: home.interaction,
          child: CupertinoApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CameraSearchRoute(clock: () => DateTime.utc(2026, 9, 5, 13)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void dispose() {
    home.dispose();
    account.dispose();
  }
}

void main() {
  testWidgets('route discovers exact index and searches with current session', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.initialize();
    addTearDown(harness.dispose);
    await harness.mount(tester, language: 'tr');
    expect(find.byType(CameraSearchScreen), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('camera-search-field')),
      'kapıdaki paket',
    );
    await tester.tap(find.byKey(const ValueKey('camera-search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('A parcel was left by the door'), findsOneWidget);
    final request = harness.requests.last;
    expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['expectedIndexRevision'], 7);
    expect(body['cameraIds'], [cameraId]);
  });

  testWidgets('home authority change discards a late route result', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final harness = _Harness(pendingSearch: pending);
    await harness.initialize();
    addTearDown(harness.dispose);
    await harness.mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('camera-search-field')),
      'parcel at door',
    );
    await tester.tap(find.byKey(const ValueKey('camera-search-submit')));
    await tester.pump();
    await harness.home.choose(HomeSource.directLocal);
    await tester.pump();
    pending.complete(_json(_page()));
    await tester.pumpAndSettle();
    expect(find.text('A parcel was left by the door'), findsNothing);
    expect(find.byType(CameraSearchScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
