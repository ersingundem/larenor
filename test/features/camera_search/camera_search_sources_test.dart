import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/camera_search/data/camera_search_api.dart';
import 'package:larenor/features/camera_search/domain/camera_search_source_models.dart';
import 'package:larenor/features/camera_search/presentation/camera_search_sources_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'camera_search_api_test.dart' as fixture;

Map<String, dynamic> source({int revision = 0}) => {
  'schemaVersion': 1,
  'revision': revision,
  'services': [
    {'id': '1' * 32, 'revision': 2, 'name': 'Home recorder'},
  ],
  'cameras': [
    {'id': '2' * 32, 'name': 'Front door'},
  ],
  'settings': revision == 0
      ? null
      : {
          'schemaVersion': 1,
          'expectedRevision': revision - 1,
          'serviceId': '1' * 32,
          'expectedServiceRevision': 2,
          'cameraResourceIds': ['2' * 32],
        },
};

ServerSession admin() {
  final s = fixture.session();
  return ServerSession(
    endpoint: s.endpoint,
    accessToken: s.accessToken,
    refreshToken: s.refreshToken,
    expiresAt: s.expiresAt,
    context: s.context,
    user: ServerUser(
      id: s.user.id,
      username: 'admin',
      role: ServerRole.admin,
      mustChangePassword: false,
    ),
  );
}

void main() {
  test('source parser rejects extra secret fields, duplicate IDs and stale settings', () {
    expect(
      CameraSearchSourceState.decode(source()).cameras.single.name,
      'Front door',
    );
    final bad = <Map<String, dynamic>>[
      {...source(), 'endpoint': 'https://private.invalid'},
      {
        ...source(),
        'cameras': [
          {'id': '2' * 32, 'name': 'A'},
          {'id': '2' * 32, 'name': 'B'},
        ],
      },
      {...source(revision: 1), 'revision': 2},
      {
        ...source(),
        'services': [
          {'id': '1' * 32, 'revision': 0, 'name': 'A'},
        ],
      },
    ];
    for (final raw in bad) {
      expect(
        () => CameraSearchSourceState.decode(raw),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
  test(
    'member cannot load private setup and retired responses cannot publish',
    () async {
      var calls = 0;
      final httpApi = LarenorServerApi(
        endpoint: fixture.session().endpoint,
        client: MockClient((r) async {
          calls++;
          return http.Response(jsonEncode(source()), 200);
        }),
      );
      addTearDown(httpApi.close);
      final member = CameraSearchApi(
        httpApi,
        fixture.session(),
        isCurrent: () => true,
      );
      await expectLater(
        member.sources(),
        throwsA(isA<LarenorServerException>()),
      );
      expect(calls, 0);
      var current = true;
      final retiredApi = LarenorServerApi(
        endpoint: admin().endpoint,
        client: MockClient((r) async {
          current = false;
          return http.Response(
            jsonEncode(source()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(retiredApi.close);
      final api = CameraSearchApi(
        retiredApi,
        admin(),
        isCurrent: () => current,
      );
      await expectLater(api.sources(), throwsA(isA<LarenorServerException>()));
    },
  );
  for (final language in ['en', 'tr']) {
    testWidgets('$language selects actual sources and saves exact CAS', (
      tester,
    ) async {
      final calls = <http.Request>[];
      final rawApi = LarenorServerApi(
        endpoint: admin().endpoint,
        client: MockClient((r) async {
          calls.add(r);
          return http.Response(
            jsonEncode(source(revision: r.method == 'PUT' ? 1 : 0)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(rawApi.close);
      final api = CameraSearchApi(rawApi, admin(), isCurrent: () => true);
      await tester.pumpWidget(
        CupertinoApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CameraSearchSourcesScreen(api: api, onDone: () {}),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(
          language == 'en'
              ? 'Verified Frigate service'
              : 'Doğrulanmış Frigate servisi',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home recorder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Front door'));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('camera-search-sources-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final sent = calls.singleWhere((r) => r.method == 'PUT');
      expect(sent.headers['authorization'], 'Bearer ${admin().accessToken}');
      expect(jsonDecode(sent.body), {
        'schemaVersion': 1,
        'expectedRevision': 0,
        'serviceId': '1' * 32,
        'expectedServiceRevision': 2,
        'cameraResourceIds': ['2' * 32],
      });
      expect(tester.takeException(), isNull);
    });
  }
}
