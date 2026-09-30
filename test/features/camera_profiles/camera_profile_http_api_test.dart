import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/camera_profiles/data/camera_profile_api.dart';
import 'package:larenor/features/camera_profiles/presentation/camera_profile_sources_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const accountId = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const profile = '55555555555555555555555555555555';
const camera = '66666666666666666666666666666666';
const area = '77777777777777777777777777777777';
const source = '88888888888888888888888888888888';
const service = '99999999999999999999999999999999';
const binding = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final class _Store implements ServerSessionPersistence {
  @override
  Future<void> write(Object? session) async {}
  @override
  Future<Never?> read() async => null;
}

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> get scope => {
  'schemaVersion': 1,
  'cameraId': camera,
  'cameraRevision': 2,
  'areaId': area,
  'areaRevision': 3,
  'serviceId': service,
  'serviceRevision': 4,
  'bindingId': binding,
  'bindingRevision': 5,
};
Map<String, dynamic> get modeAway => {
  'recording': 'enabled',
  'detection': 'enabled',
};
Map<String, dynamic> get modeHome => {
  'recording': 'paused',
  'detection': 'disabled',
};
Map<String, dynamic> get authority => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'homeRevision': 1,
  'accountId': accountId,
  'accountRevision': 2,
  'sessionFamilyId': family,
  'role': 'admin',
  'active': true,
  'canManageCameraProfiles': true,
};
Map<String, dynamic> get policy => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'profileId': profile,
  'profileRevision': 3,
  'presenceSourceId': source,
  'presenceSourceRevision': 4,
  'cameras': [scope],
  'enterDelayMs': 0,
  'exitDelayMs': 0,
  'hysteresisMs': 0,
  'presenceMaxAgeMs': 60000,
  'atHomeMode': modeHome,
  'awayMode': modeAway,
  'failSafeMode': modeAway,
  'active': true,
};
Map<String, dynamic> get signal => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'sourceId': source,
  'sourceRevision': 4,
  'signalRevision': 5,
  'observedAtMs': 1000,
  'state': 'home',
};
Map<String, dynamic> get decision => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'homeRevision': 1,
  'profileId': profile,
  'profileRevision': 3,
  'policyHash': 'b' * 64,
  'actorAccountId': accountId,
  'accountRevision': 2,
  'sessionFamilyId': family,
  'presenceSourceId': source,
  'presenceSourceRevision': 4,
  'signalRevision': 5,
  'evaluatedAtMs': 1000,
  'reason': 'presence_home',
  'mode': modeHome,
  'targets': [
    {'schemaVersion': 1, 'camera': scope, 'mode': modeHome},
  ],
};
Map<String, dynamic> get snapshot => {
  'schemaVersion': 1,
  'authority': authority,
  'policy': policy,
  'signal': signal,
  'decision': decision,
  'readbacks': [
    {
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
      'camera': scope,
      'stateRevision': 6,
      'mode': modeAway,
      'observedAtMs': 1000,
    },
  ],
  'support': [
    {
      'schemaVersion': 1,
      'camera': scope,
      'displayName': 'Front door',
      'providerRevision': 7,
      'recordingSupported': false,
      'detectionSupported': false,
      'verifiedAtMs': 1000,
    },
  ],
  'privacyBoundary': {
    'microphoneDisabled': false,
    'cameraHardwareDisabled': false,
    'otherRecordersDisabled': false,
  },
};

Future<ServerAccountController> _account(
  Future<http.Response> Function(http.Request) handler,
) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) =>
        LarenorServerApi(endpoint: endpoint, client: MockClient(handler)),
  );
  await account.signIn(
    baseUrl: 'https://core.invalid',
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'tablet',
  );
  return account;
}

void main() {
  for (final language in ['en', 'tr']) {
    testWidgets(
      'source bindings remain editable after unavailable recovery in $language',
      (tester) async {
        final calls = <http.Request>[];
        final account = await _account((request) async {
          calls.add(request);
          if (request.url.path.endsWith('/auth/login')) {
            return _json({
              'accessToken': 'a' * 43,
              'refreshToken': 'b' * 43,
              'expiresIn': 3600,
              'user': {
                'id': accountId,
                'username': 'admin',
                'role': 'admin',
                'mustChangePassword': false,
              },
            });
          }
          if (request.url.path.endsWith('/context')) {
            return _json({'schemaVersion': 1, 'coreId': core, 'homeId': home});
          }
          if (request.url.path.endsWith('/recovery')) {
            return _json({
              'error': {'code': 'camera_profile_provider_unavailable'},
            }, 503);
          }
          return _json({
            'source': {
              'schemaVersion': 1,
              'revision': 1,
              'settings': {
                'schemaVersion': 1,
                'expectedRevision': 0,
                'presenceResourceId': source,
                'cameras': [
                  {
                    'recordingResourceId': camera,
                    'detectionResourceId': binding,
                    'areaId': area,
                  },
                ],
                'enterDelayMs': 0,
                'exitDelayMs': 1000,
                'hysteresisMs': 0,
                'presenceMaxAgeMs': 60000,
                'atHomeMode': modeHome,
                'awayMode': modeAway,
                'failSafeMode': modeAway,
              },
              'resources': [
                {'id': source, 'name': 'Presence fixture', 'domain': 'person'},
                {'id': camera, 'name': 'Recording fixture', 'domain': 'switch'},
                {
                  'id': binding,
                  'name': 'Detection fixture',
                  'domain': 'switch',
                },
              ],
              'areas': [
                {'id': area, 'name': 'Entry fixture'},
              ],
            },
          });
        });
        addTearDown(account.dispose);
        final api = CoreCameraProfileApi(
          account: account,
          routeId: 'd' * 32,
          sessionRevision: 1,
          routeRevision: 1,
          isCurrent: () => true,
        );
        addTearDown(api.retire);
        await tester.pumpWidget(
          CupertinoApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CameraProfileSourcesScreen(api: api, onDone: () {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Presence fixture'), findsOneWidget);
        // Provider recovery failure must not remove configuration controls.
        await tester.tap(find.text('Presence fixture'));
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoActionSheet), findsOneWidget);
        expect(
          calls.where(
            (request) =>
                request.method == 'POST' &&
                !request.url.path.endsWith('/auth/login'),
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'camera source CAS saves only explicit bindings and retires late replies',
    () async {
      var current = true;
      final calls = <http.Request>[];
      final settings = {
        'schemaVersion': 1,
        'expectedRevision': 0,
        'presenceResourceId': source,
        'cameras': [
          {
            'recordingResourceId': camera,
            'detectionResourceId': binding,
            'areaId': area,
          },
        ],
        'enterDelayMs': 0,
        'exitDelayMs': 1000,
        'hysteresisMs': 0,
        'presenceMaxAgeMs': 60000,
        'atHomeMode': modeHome,
        'awayMode': modeAway,
        'failSafeMode': modeAway,
      };
      final account = await _account((request) async {
        calls.add(request);
        if (request.url.path.endsWith('/auth/login')) {
          return _json({
            'accessToken': 'a' * 43,
            'refreshToken': 'b' * 43,
            'expiresIn': 3600,
            'user': {
              'id': accountId,
              'username': 'admin',
              'role': 'admin',
              'mustChangePassword': false,
            },
          });
        }
        if (request.url.path.endsWith('/context')) {
          return _json({'schemaVersion': 1, 'coreId': core, 'homeId': home});
        }
        expect(
          request.url.path,
          '/api/v1/admin/camera-profiles/$core/$home/sources',
        );
        if (request.method == 'PUT') expect(jsonDecode(request.body), settings);
        return _json({
          'source': {
            'schemaVersion': 1,
            'revision': request.method == 'PUT' ? 1 : 0,
            'settings': request.method == 'PUT' ? settings : null,
            'resources': [
              {'id': source, 'name': 'Presence', 'domain': 'person'},
              {'id': camera, 'name': 'Recording', 'domain': 'switch'},
              {'id': binding, 'name': 'Detection', 'domain': 'switch'},
            ],
            'areas': [
              {'id': area, 'name': 'Entry'},
            ],
          },
        });
      });
      addTearDown(account.dispose);
      final api = CoreCameraProfileApi(
        account: account,
        routeId: 'd' * 32,
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => current,
      );
      expect((await api.sources()).revision, 0);
      expect((await api.configureSources(settings)).revision, 1);
      expect(calls.where((r) => r.url.path.contains('/apply')), isEmpty);
      current = false;
      final before = calls.length;
      await expectLater(api.sources(), throwsA(isA<LarenorServerException>()));
      expect(calls.length, before);
    },
  );

  test(
    'authenticated client sends exact snapshot and preserves failed readback',
    () async {
      final requests = <http.Request>[];
      final account = await _account((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/login')) {
          return _json({
            'accessToken': 'a' * 43,
            'refreshToken': 'b' * 43,
            'expiresIn': 3600,
            'user': {
              'id': accountId,
              'username': 'admin',
              'role': 'admin',
              'mustChangePassword': false,
            },
          });
        }
        if (request.url.path.endsWith('/context')) {
          return _json({'schemaVersion': 1, 'coreId': core, 'homeId': home});
        }
        if (request.method == 'GET') return _json({'snapshot': snapshot});
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['authority'], authority);
        expect(body['support'], snapshot['support']);
        return _json({
          'receipt': {
            'schemaVersion': 1,
            'requestId': body['requestId'],
            'profileId': profile,
            'profileRevision': 3,
            'status': 'failed',
            'createdAtMs': 1001,
            'results': [
              {
                'schemaVersion': 1,
                'commandId': 'c' * 32,
                'cameraId': camera,
                'status': 'failed',
                'code': 'provider_unsupported',
                'readback': null,
              },
            ],
          },
        });
      });
      addTearDown(account.dispose);
      final api = CoreCameraProfileApi(
        account: account,
        routeId: 'd' * 32,
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => true,
      );
      final current = await api.bootstrap();
      expect(current.cameras.single.name, 'Front door');
      expect(current.makesNoHardwarePrivacyClaim, isTrue);
      final receipt = await api.apply(current);
      expect(receipt.status, 'failed');
      expect(receipt.results.single.code, 'provider_unsupported');
      expect(requests.last.headers['authorization'], 'Bearer ${'a' * 43}');
      expect(
        requests.last.url.path,
        '/api/v1/admin/camera-profiles/$core/$home/apply',
      );
    },
  );

  test(
    'client rejects a provider claim that camera hardware is disabled',
    () async {
      final unsafe = Map<String, dynamic>.from(snapshot);
      unsafe['privacyBoundary'] = {
        'microphoneDisabled': true,
        'cameraHardwareDisabled': false,
        'otherRecordersDisabled': false,
      };
      final account = await _account((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return _json({
            'accessToken': 'a' * 43,
            'refreshToken': 'b' * 43,
            'expiresIn': 3600,
            'user': {
              'id': accountId,
              'username': 'admin',
              'role': 'admin',
              'mustChangePassword': false,
            },
          });
        }
        if (request.url.path.endsWith('/context')) {
          return _json({'schemaVersion': 1, 'coreId': core, 'homeId': home});
        }
        return _json({'snapshot': unsafe});
      });
      addTearDown(account.dispose);
      final api = CoreCameraProfileApi(
        account: account,
        routeId: 'd' * 32,
        sessionRevision: 1,
        routeRevision: 2,
        isCurrent: () => true,
      );
      await expectLater(
        api.bootstrap(),
        throwsA(isA<LarenorServerException>()),
      );
    },
  );
}
