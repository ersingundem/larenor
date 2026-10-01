import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_v2_port.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';
import 'package:larenor/features/game_streaming/data/game_stream_client_controller.dart';
import 'package:larenor/features/game_streaming/data/game_stream_recovery_store.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _channel = MethodChannel('com.ersingundem.larenor/game-stream-native');
const _hostId = '7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f';
const _appId = '8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f';
const _pairingId = '11111111111111111111111111111111';
const _catalogId = '12121212121212121212121212121212';

http.Response _response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, Object?> _host(int catalogRevision) => {
  'schemaVersion': 2,
  'id': _hostId,
  'revision': 1,
  'pairingRevision': 1,
  'catalogRevision': catalogRevision,
  'name': 'Owned Sunshine fixture',
  'assurance': 'native_observed',
  'active': true,
  'codecs': ['h264'],
};

Map<String, Object?> _app() => {
  'schemaVersion': 2,
  'id': _appId,
  'hostId': _hostId,
  'revision': 1,
  'name': 'Desktop',
  'active': true,
};

Map<String, Object?> _pairObservation(String requestId) => {
  'schemaVersion': 2,
  'requestId': requestId,
  'pairingId': _pairingId,
  'state': 'paired',
  'nativeReceiptDigest': 'd' * 64,
  'observation': {
    'schemaVersion': 1,
    'receiptId': '33333333333333333333333333333333',
    'nativeBindingId': '44444444444444444444444444444444',
    'bindingRevision': 1,
    'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
    'provider': 'moonlight-nvhttp',
    'state': 'paired',
    'hostObservationId': '55555555555555555555555555555555',
    'name': 'Owned Sunshine fixture',
    'codecs': ['h264'],
    'catalogRevision': 1,
    'catalogDigest': 'a' * 64,
    'apps': <Object>[],
  },
};

ServerSession _session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2027),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
  }),
  sessionFamilyId: 'f' * 32,
  user: ServerUser(
    id: 'c' * 32,
    username: 'fixture',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

AndroidGameStreamAuthorityV2 _authority(int accountRevision) =>
    AndroidGameStreamAuthorityV2(
      clientInstanceId: '0' * 32,
      coreId: 'a' * 32,
      homeId: 'b' * 32,
      accountId: 'c' * 32,
      familyId: 'f' * 32,
      accountRevision: accountRevision,
      pinRevision: 1,
      pinConfigured: true,
      pinUnlocked: true,
      routeRevision: 1,
      lifecycleRevision: 1,
      idleRevision: 1,
      interactionRevision: 1,
    );

AndroidGameStreamAuthorityV2 _authorityWithoutPin(int accountRevision) =>
    AndroidGameStreamAuthorityV2(
      clientInstanceId: '0' * 32,
      coreId: 'a' * 32,
      homeId: 'b' * 32,
      accountId: 'c' * 32,
      familyId: 'f' * 32,
      accountRevision: accountRevision,
      pinRevision: 1,
      pinConfigured: false,
      pinUnlocked: false,
      routeRevision: 1,
      lifecycleRevision: 1,
      idleRevision: 1,
      interactionRevision: 1,
    );

AndroidGameStreamPolicyDraft _pinPolicy() => AndroidGameStreamPolicyDraft(
  allowedCodecs: const ['h264'],
  allowMetered: false,
  requirePin: true,
  maxWidth: 1920,
  maxHeight: 1080,
  maxFps: 60,
  maxBitrateKbps: 20000,
  maximumIdleSeconds: 300,
  maximumSessionSeconds: 3600,
  frameQueueDepth: 2,
  inputQueueDepth: 1,
);

Map<String, Object> _quality() => {
  'codec': 'h264',
  'codecId': 'a' * 32,
  'codecRevision': 9,
  'displayId': 0,
  'displayRevision': 6,
  'networkId': 'b' * 32,
  'networkRevision': 7,
  'policyId': 'c' * 32,
  'policyRevision': 8,
  'widthPixels': 1920,
  'heightPixels': 1080,
  'framesPerSecond': 60,
  'bitrateKbps': 20000,
  'frameQueueDepth': 2,
  'inputQueueDepth': 1,
  'secureSurface': true,
};

Map<String, Object?> _coreSession({String state = 'open', int revision = 1}) =>
    {
      'schemaVersion': 2,
      'id': '7' * 32,
      'hostId': _hostId,
      'appId': _appId,
      'revision': revision,
      'state': state,
      'expiresAt': 1800000000.0,
      'coreAuthority': {
        'accountRevision': 7,
        'hostRevision': 1,
        'pairingRevision': 1,
        'catalogRevision': 1,
        'appRevision': 1,
        'selectedQuality': _quality(),
      },
      'selectedQuality': _quality(),
      'clientAuthority': {
        'routeRevision': 1,
        'lifecycleRevision': 1,
        'displayRevision': 6,
        'networkRevision': 7,
        'policyRevision': 8,
      },
    };

Map<String, Object?> _coreCommand(
  String id,
  String intent, {
  String state = 'authorized',
}) => {
  'schemaVersion': 2,
  'id': id,
  'sessionId': '7' * 32,
  'intent': intent,
  'state': state,
  'result': state == 'native_observed'
      ? (intent == 'stop' ? 'stopped' : 'streaming')
      : null,
  'observationKind': state == 'native_observed'
      ? (intent == 'stop' ? 'connectionStopped' : 'connectionStarted')
      : null,
  'readbackRevision': state == 'native_observed'
      ? (intent == 'stop' ? 2 : 1)
      : null,
  'createdAt': 1790000000.0,
  'completedAt': state == 'native_observed' ? 1790000001.0 : null,
};

Map<String, Object?> _availableCapabilities(String requestId) => {
  'schemaVersion': 2,
  'requestId': requestId,
  'availability': 'available',
  'reason': null,
  'display': {
    'displayId': 0,
    'displayRevision': 6,
    'attached': true,
    'widthPixels': 1920,
    'heightPixels': 1080,
    'densityDpi': 320,
    'secureSurface': true,
    'maxRefreshRate': 60,
  },
  'network': {
    'networkId': 'b' * 32,
    'networkRevision': 7,
    'reachability': 'local',
    'metered': false,
  },
  'decoders': [
    {
      'codecId': 'a' * 32,
      'codecRevision': 9,
      'codec': 'h264',
      'supported': true,
      'maxWidthPixels': 1920,
      'maxHeightPixels': 1080,
      'maxFramesPerSecond': 60,
    },
  ],
  'policy': {
    'policyId': 'c' * 32,
    'policyRevision': 8,
    'allowedCodecIds': ['a' * 32],
    'allowMetered': false,
    'requirePin': true,
    'maxWidth': 1920,
    'maxHeight': 1080,
    'maxFps': 60,
    'maxBitrateKbps': 20000,
    'maximumIdleSeconds': 300,
    'maximumSessionSeconds': 3600,
    'frameQueueDepth': 2,
    'inputQueueDepth': 1,
  },
  'qualityOptions': [_quality()],
};

final class _MemoryRecoveryBackend implements GameStreamRecoveryBackend {
  String? value;
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('recovery_read_failed');
    return value;
  }

  @override
  Future<void> write(String next) async {
    if (failWrite) throw StateError('recovery_write_failed');
    value = next;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test('PIN-required policy is rejected before native configuration', () async {
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      nativeCalls += 1;
      fail(
        'PIN-required policy must not cross to native without PIN assurance',
      );
    });
    final session = _session();
    final transport = LarenorServerApi(
      endpoint: session.endpoint,
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, endsWith('/hosts'));
        return _response({
          'schemaVersion': 2,
          'scope': {'schemaVersion': 1, 'coreId': 'a' * 32, 'homeId': 'b' * 32},
          'accountRevision': 7,
          'hosts': <Object>[],
        });
      }),
    );
    addTearDown(transport.close);
    final controller = GameStreamClientController(
      core: CoreGameStreamApi(transport, session, isCurrent: () => true),
      native: AndroidGameStreamV2Port(),
      authority: _authorityWithoutPin,
      isCurrent: () => true,
      recoveryStore: GameStreamRecoveryStore(backend: _MemoryRecoveryBackend()),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.configurePolicy(_pinPolicy());

    expect(nativeCalls, 0);
    expect(controller.state.errorCode, 'pin_required');
  });

  test(
    'PIN authority drift blocks session creation before Core effect',
    () async {
      var pinUnlocked = true;
      var coreSessionCreates = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final requestId = args['requestId'];
        switch (call.method) {
          case 'resolveBindingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 1,
              'registrationRevision': 1,
              'hostId': _hostId,
              'appId': _appId,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            };
          case 'sessionCapabilitiesV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'availability': 'available',
              'reason': null,
              'display': {
                'displayId': 0,
                'displayRevision': 6,
                'attached': true,
                'widthPixels': 1920,
                'heightPixels': 1080,
                'densityDpi': 320,
                'secureSurface': true,
                'maxRefreshRate': 60,
              },
              'network': {
                'networkId': 'b' * 32,
                'networkRevision': 7,
                'reachability': 'local',
                'metered': false,
              },
              'decoders': [
                {
                  'codecId': 'a' * 32,
                  'codecRevision': 9,
                  'codec': 'h264',
                  'supported': true,
                  'maxWidthPixels': 1920,
                  'maxHeightPixels': 1080,
                  'maxFramesPerSecond': 60,
                },
              ],
              'policy': {
                'policyId': 'c' * 32,
                'policyRevision': 8,
                'allowedCodecIds': ['a' * 32],
                'allowMetered': false,
                'requirePin': true,
                'maxWidth': 1920,
                'maxHeight': 1080,
                'maxFps': 60,
                'maxBitrateKbps': 20000,
                'maximumIdleSeconds': 300,
                'maximumSessionSeconds': 3600,
                'frameQueueDepth': 2,
                'inputQueueDepth': 1,
              },
              'qualityOptions': [
                {
                  'codec': 'h264',
                  'codecId': 'a' * 32,
                  'codecRevision': 9,
                  'displayId': 0,
                  'displayRevision': 6,
                  'networkId': 'b' * 32,
                  'networkRevision': 7,
                  'policyId': 'c' * 32,
                  'policyRevision': 8,
                  'widthPixels': 1920,
                  'heightPixels': 1080,
                  'framesPerSecond': 60,
                  'bitrateKbps': 20000,
                  'frameQueueDepth': 2,
                  'inputQueueDepth': 1,
                  'secureSurface': true,
                },
              ],
            };
          default:
            fail('unexpected native method ${call.method}');
        }
      });
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': [_host(1)],
            });
          }
          if (request.method == 'GET' && path.endsWith('/apps')) {
            return _response({
              'schemaVersion': 2,
              'hostRevision': 1,
              'pairingRevision': 1,
              'catalogRevision': 1,
              'apps': [_app()],
            });
          }
          if (request.method == 'POST' && path.endsWith('/sessions')) {
            coreSessionCreates += 1;
            return _response({'error': 'must_not_create'}, 500);
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      AndroidGameStreamAuthorityV2 authority(int accountRevision) =>
          AndroidGameStreamAuthorityV2(
            clientInstanceId: '0' * 32,
            coreId: 'a' * 32,
            homeId: 'b' * 32,
            accountId: 'c' * 32,
            familyId: 'f' * 32,
            accountRevision: accountRevision,
            pinRevision: pinUnlocked ? 1 : 2,
            pinConfigured: true,
            pinUnlocked: pinUnlocked,
            routeRevision: 1,
            lifecycleRevision: 1,
            idleRevision: 1,
            interactionRevision: 1,
          );
      final controller = GameStreamClientController(
        core: CoreGameStreamApi(transport, session, isCurrent: () => true),
        native: AndroidGameStreamV2Port(),
        authority: authority,
        isCurrent: () => true,
        recoveryStore: GameStreamRecoveryStore(
          backend: _MemoryRecoveryBackend(),
        ),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.selectHost(controller.state.hosts.single);
      await controller.selectApp(controller.state.apps.single);
      expect(controller.state.capabilities?.policy?.requirePin, isTrue);
      pinUnlocked = false;

      await controller.start();

      expect(controller.state.errorCode, 'pin_required');
      expect(coreSessionCreates, 0);
    },
  );

  test(
    'pair callback loss reconciles without resend and zero-app host refreshes',
    () async {
      final nativeCalls = <String>[];
      var pairingDispatches = 0;
      var catalogDispatches = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        nativeCalls.add(call.method);
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final requestId = args['requestId'] as String?;
        switch (call.method) {
          case 'beginPairingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '44444444444444444444444444444444',
              'bindingRevision': 1,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
              'provider': 'moonlight-nvhttp',
              'catalogRevision': 1,
              'catalogDigest': 'a' * 64,
              'candidates': [
                {
                  'candidateId': '55555555555555555555555555555555',
                  'revision': 1,
                  'name': 'Owned Sunshine fixture',
                  'powerState': 'awake',
                  'pairState': 'notPaired',
                },
              ],
            };
          case 'pairHostV2':
            pairingDispatches += 1;
            throw PlatformException(code: 'callback_lost');
          case 'reconcileV2':
            final kind = args['operationKind'];
            if (kind == 'catalog') {
              expect(args['operationId'], _catalogId);
              return {
                'schemaVersion': 2,
                'requestId': requestId,
                'operationKind': 'catalog',
                'terminal': true,
                'receipt': {
                  'schemaVersion': 2,
                  'requestId': requestId,
                  'catalogObservationId': _catalogId,
                  'state': 'observed',
                  'nativeReceiptDigest': 'f' * 64,
                  'observation': {
                    'schemaVersion': 1,
                    'receiptId': '14141414141414141414141414141414',
                    'nativeBindingId': '44444444444444444444444444444444',
                    'bindingRevision': 1,
                    'catalogRevision': 2,
                    'catalogDigest': 'b' * 64,
                    'apps': [
                      {
                        'observationId': '66666666666666666666666666666666',
                        'revision': 1,
                        'name': 'Desktop',
                      },
                    ],
                  },
                },
              };
            }
            expect(kind, 'pair');
            expect(args['operationId'], _pairingId);
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'operationKind': 'pair',
              'terminal': true,
              'receipt': _pairObservation(requestId!),
            };
          case 'commitRegistrationV2':
            final apps = args['apps']! as List;
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'registrationRevision': 1,
              'hostId': _hostId,
              'appIds': apps
                  .map((item) => (item as Map)['id'])
                  .toList(growable: false),
              'nativeReceiptDigest': 'e' * 64,
            };
          case 'resolveHostBindingV2':
            expect(args.keys, isNot(contains('appId')));
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '44444444444444444444444444444444',
              'bindingRevision': 1,
              'registrationRevision': 1,
              'hostId': _hostId,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            };
          case 'readCatalogV2':
            catalogDispatches += 1;
            throw PlatformException(code: 'callback_lost');
          default:
            fail('unexpected native method ${call.method}');
        }
      });

      var publishedCatalogRevision = 0;
      final coreCalls = <String>[];
      final transport = LarenorServerApi(
        endpoint: _session().endpoint,
        client: MockClient((request) async {
          coreCalls.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': publishedCatalogRevision == 0
                  ? <Object>[]
                  : [_host(publishedCatalogRevision)],
            });
          }
          if (request.method == 'POST' && path.endsWith('/pairings')) {
            return _response({
              'schemaVersion': 2,
              'id': _pairingId,
              'revision': 1,
              'state': 'pending',
              'pairingGrant': '22222222222222222222222222222222',
              'expiresAt': 1800000000.0,
            }, 201);
          }
          if (request.method == 'POST' &&
              path.endsWith('/pairings/$_pairingId/complete')) {
            publishedCatalogRevision = 1;
            return _response({
              'schemaVersion': 2,
              'host': _host(1),
              'apps': <Object>[],
              'registrationMapping': {
                'nativeReceiptId': '33333333333333333333333333333333',
                'hostId': _hostId,
                'apps': <Object>[],
              },
            });
          }
          if (request.method == 'POST' &&
              path.endsWith('/catalog-observations')) {
            return _response({
              'schemaVersion': 2,
              'id': _catalogId,
              'hostId': _hostId,
              'revision': 1,
              'state': 'pending',
              'catalogGrant': '13131313131313131313131313131313',
              'expiresAt': 1800000000.0,
            }, 201);
          }
          if (request.method == 'POST' &&
              path.endsWith('/$_catalogId/complete')) {
            publishedCatalogRevision = 2;
            return _response({
              'schemaVersion': 2,
              'hostRevision': 1,
              'pairingRevision': 1,
              'catalogRevision': 2,
              'apps': [_app()],
              'registrationMapping': {
                'nativeReceiptId': '14141414141414141414141414141414',
                'hostId': _hostId,
                'apps': [
                  {'entryIndex': 0, 'appId': _appId},
                ],
              },
            });
          }
          if (request.method == 'GET' && path.endsWith('/apps')) {
            return _response({
              'schemaVersion': 2,
              'hostRevision': 1,
              'pairingRevision': 1,
              'catalogRevision': 2,
              'apps': [_app()],
            });
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      final session = _session();
      final backend = _MemoryRecoveryBackend();
      GameStreamClientController buildController() =>
          GameStreamClientController(
            core: CoreGameStreamApi(transport, session, isCurrent: () => true),
            native: AndroidGameStreamV2Port(),
            authority: _authority,
            isCurrent: () => true,
            recoveryStore: GameStreamRecoveryStore(backend: backend),
            now: () => DateTime.utc(2026, 10, 1),
          );

      final controller = buildController();

      await controller.initialize();
      await controller.beginPairing();
      await controller.pair(controller.state.candidates.single);
      expect(pairingDispatches, 1);
      expect(controller.state.selectedHost?.id, _hostId);
      expect(controller.state.apps, isEmpty);

      await controller.refreshCatalog();
      expect(pairingDispatches, 1);
      expect(catalogDispatches, 1);
      expect(controller.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(backend.value, isNotNull);
      controller.dispose();

      final recovered = buildController();
      addTearDown(recovered.dispose);
      await recovered.initialize();
      expect(recovered.state.apps.single.id, _appId);
      expect(catalogDispatches, 1);
      expect(backend.value, isNull);
      expect(nativeCalls, contains('resolveHostBindingV2'));
      expect(nativeCalls, isNot(contains('resolveBindingV2')));
      expect(
        coreCalls.where((item) => item.endsWith('/catalog-observations')),
        hasLength(1),
      );
    },
  );

  test('revocation callback loss becomes unknown and cannot resend', () async {
    var nativeRevocations = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final requestId = args['requestId'] as String?;
      if (call.method == 'revokePairingV2') {
        nativeRevocations += 1;
        throw PlatformException(code: 'callback_lost');
      }
      if (call.method == 'reconcileV2') {
        expect(args['operationKind'], 'revoke');
        expect(args['operationId'], 'e' * 32);
        return {
          'schemaVersion': 2,
          'requestId': requestId,
          'operationKind': 'revoke',
          'terminal': true,
          'receipt': {
            'schemaVersion': 2,
            'requestId': requestId,
            'revocationId': 'e' * 32,
            'state': 'unknown',
            'readbackRevision': null,
            'nativeReceiptDigest': null,
          },
        };
      }
      fail('unexpected native method ${call.method}');
    });

    var coreRevocations = 0;
    var hostVisible = true;
    final session = _session();
    final transport = LarenorServerApi(
      endpoint: session.endpoint,
      client: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path.endsWith('/hosts')) {
          return _response({
            'schemaVersion': 2,
            'scope': {
              'schemaVersion': 1,
              'coreId': 'a' * 32,
              'homeId': 'b' * 32,
            },
            'accountRevision': 7,
            'hosts': hostVisible ? [_host(1)] : <Object>[],
          });
        }
        if (request.method == 'POST' && path.endsWith('/revoke')) {
          coreRevocations += 1;
          hostVisible = false;
          return _response({
            'schemaVersion': 2,
            'id': 'e' * 32,
            'hostId': _hostId,
            'hostRevision': 2,
            'state': 'core_retired',
            'readbackRevision': null,
            'nativeReceiptDigest': null,
            'createdAt': 1800000000.0,
            'completedAt': null,
          }, 201);
        }
        if (request.method == 'POST' && path.endsWith('/complete')) {
          return _response({
            'schemaVersion': 2,
            'id': 'e' * 32,
            'hostId': _hostId,
            'hostRevision': 2,
            'state': 'unknown',
            'readbackRevision': null,
            'nativeReceiptDigest': null,
            'createdAt': 1800000000.0,
            'completedAt': 1800000001.0,
          });
        }
        fail('unexpected Core request ${request.method} $path');
      }),
    );
    addTearDown(transport.close);
    final backend = _MemoryRecoveryBackend();
    GameStreamClientController buildController() => GameStreamClientController(
      core: CoreGameStreamApi(transport, session, isCurrent: () => true),
      native: AndroidGameStreamV2Port(),
      authority: _authority,
      isCurrent: () => true,
      recoveryStore: GameStreamRecoveryStore(backend: backend),
    );
    final controller = buildController();

    await controller.initialize();
    final host = controller.state.hosts.single;
    await controller.revoke(host);
    expect(controller.state.phase, GameStreamClientPhase.outcomeUnknown);
    expect(coreRevocations, 1);
    expect(nativeRevocations, 1);
    expect(backend.value, isNotNull);
    controller.dispose();

    final recovered = buildController();
    addTearDown(recovered.dispose);
    await recovered.initialize();
    expect(recovered.state.phase, GameStreamClientPhase.outcomeUnknown);
    expect(recovered.state.hosts, isEmpty);
    expect(coreRevocations, 1);
    expect(nativeRevocations, 1);
  });

  test(
    'restart reconciles pending pairing and never dispatches twice',
    () async {
      var nativeDispatches = 0;
      var reconcileTerminal = false;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final requestId = args['requestId'] as String?;
        switch (call.method) {
          case 'beginPairingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '44444444444444444444444444444444',
              'bindingRevision': 1,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
              'provider': 'moonlight-nvhttp',
              'catalogRevision': 1,
              'catalogDigest': 'a' * 64,
              'candidates': [
                {
                  'candidateId': '55555555555555555555555555555555',
                  'revision': 1,
                  'name': 'Owned Sunshine fixture',
                  'powerState': 'awake',
                  'pairState': 'notPaired',
                },
              ],
            };
          case 'pairHostV2':
            nativeDispatches += 1;
            throw PlatformException(code: 'callback_lost');
          case 'reconcileV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'operationKind': 'pair',
              'terminal': reconcileTerminal,
              'receipt': reconcileTerminal
                  ? _pairObservation(requestId!)
                  : null,
            };
          case 'commitRegistrationV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'registrationRevision': 1,
              'hostId': _hostId,
              'appIds': <Object>[],
              'nativeReceiptDigest': 'e' * 64,
            };
          default:
            fail('unexpected native method ${call.method}');
        }
      });

      var registered = false;
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': registered ? [_host(1)] : <Object>[],
            });
          }
          if (request.method == 'POST' && path.endsWith('/pairings')) {
            return _response({
              'schemaVersion': 2,
              'id': _pairingId,
              'revision': 1,
              'state': 'pending',
              'pairingGrant': '22222222222222222222222222222222',
              'expiresAt': 1800000000.0,
            }, 201);
          }
          if (request.method == 'POST' && path.endsWith('/complete')) {
            registered = true;
            return _response({
              'schemaVersion': 2,
              'host': _host(1),
              'apps': <Object>[],
              'registrationMapping': {
                'nativeReceiptId': '33333333333333333333333333333333',
                'hostId': _hostId,
                'apps': <Object>[],
              },
            });
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      final backend = _MemoryRecoveryBackend();

      GameStreamClientController buildController() =>
          GameStreamClientController(
            core: CoreGameStreamApi(transport, session, isCurrent: () => true),
            native: AndroidGameStreamV2Port(),
            authority: _authority,
            isCurrent: () => true,
            recoveryStore: GameStreamRecoveryStore(backend: backend),
            now: () => DateTime.utc(2026, 10, 1),
          );

      final first = buildController();
      await first.initialize();
      await first.beginPairing();
      await first.pair(first.state.candidates.single);
      expect(first.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(nativeDispatches, 1);
      expect(backend.value, isNotNull);
      first.dispose();

      reconcileTerminal = true;
      final second = buildController();
      addTearDown(second.dispose);
      await second.initialize();
      expect(second.state.phase, GameStreamClientPhase.idle);
      expect(second.state.selectedHost?.id, _hostId);
      expect(nativeDispatches, 1);
      expect(backend.value, isNull);
    },
  );

  test(
    'stop uses the stored native lease after client capability drift',
    () async {
      var drifted = false;
      var hostReads = 0;
      var appReads = 0;
      var capabilityReads = 0;
      var commandSequence = 0;
      final commandIntents = <String, String>{};
      final retiredEpochs = <int>[];
      var failNativeRetire = false;
      var failCoreRetire = false;
      var wrongCoreRetireId = false;
      var scopeChanged = false;
      var coreSessionRetired = false;
      var coreRetireCalls = 0;
      var nativeStopDispatches = 0;
      final recoveryBackend = _MemoryRecoveryBackend();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final requestId = args['requestId'] as String?;
        switch (call.method) {
          case 'resolveBindingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 3,
              'registrationRevision': 4,
              'hostId': _hostId,
              'appId': _appId,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            };
          case 'sessionCapabilitiesV2':
            capabilityReads += 1;
            return _availableCapabilities(requestId!);
          case 'bindSessionV2':
            return null;
          case 'executeV2':
            final command = Map<Object?, Object?>.from(args['command']! as Map);
            final intent = command['intent'];
            if (intent == 'stop') {
              nativeStopDispatches += 1;
              expect(args['authority'], containsPair('routeRevision', 1));
              expect(args['safetyClosure'], {
                'nativeBindingId': '4' * 32,
                'bindingRevision': 3,
              });
            } else {
              expect(args.keys, isNot(contains('safetyClosure')));
            }
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'sessionId': '7' * 32,
              'commandId': command['id'],
              'state': 'native_observed',
              'result': intent == 'stop' ? 'stopped' : 'streaming',
              'observationKind': intent == 'stop'
                  ? 'connectionStopped'
                  : 'connectionStarted',
              'readbackRevision': intent == 'stop' ? 2 : 1,
              'nativeReceiptDigest': intent == 'stop' ? '2' * 64 : '1' * 64,
            };
          case 'retire':
            retiredEpochs.add(args['epoch']! as int);
            if (failNativeRetire) {
              throw PlatformException(code: 'authority_changed');
            }
            return {
              'schemaVersion': 2,
              'sessionId': args['sessionId'],
              'epoch': args['epoch'],
              'state': 'retired',
            };
          default:
            fail('unexpected native method ${call.method}');
        }
      });
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            hostReads += 1;
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': [_host(1)],
            });
          }
          if (request.method == 'GET' && path.endsWith('/apps')) {
            appReads += 1;
            return _response({
              'schemaVersion': 2,
              'hostRevision': 1,
              'pairingRevision': 1,
              'catalogRevision': 1,
              'apps': [_app()],
            });
          }
          if (request.method == 'POST' && path.endsWith('/sessions')) {
            coreSessionRetired = false;
            return _response(_coreSession(), 201);
          }
          if (request.method == 'GET' && path.endsWith('/${'7' * 32}')) {
            return _response(
              coreSessionRetired
                  ? _coreSession(state: 'retired', revision: 2)
                  : _coreSession(),
            );
          }
          if (request.method == 'POST' && path.endsWith('/commands')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final intent = body['intent']! as String;
            commandSequence += 1;
            final id = commandSequence.toRadixString(16).padLeft(32, '0');
            commandIntents[id] = intent;
            return _response({
              'schemaVersion': 2,
              'command': _coreCommand(id, intent),
              'dispatchGrant': commandSequence.isOdd ? '5' * 32 : '6' * 32,
            }, 201);
          }
          if (request.method == 'POST' && path.endsWith('/complete')) {
            final id = path.split('/').reversed.elementAt(1);
            final intent = commandIntents[id]!;
            return _response(
              _coreCommand(id, intent, state: 'native_observed'),
            );
          }
          if (request.method == 'GET' && path.contains('/commands/')) {
            final id = path.split('/').last;
            final intent = commandIntents[id]!;
            return _response(
              _coreCommand(id, intent, state: 'native_observed'),
            );
          }
          if (request.method == 'POST' && path.endsWith('/retire')) {
            coreRetireCalls += 1;
            if (failCoreRetire) {
              return _response({'error': 'server_unavailable'}, 503);
            }
            coreSessionRetired = true;
            final retired = _coreSession(state: 'retired', revision: 2);
            if (wrongCoreRetireId) retired['id'] = '6' * 32;
            return _response(retired);
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      AndroidGameStreamAuthorityV2 authority(int accountRevision) {
        final current = _authority(accountRevision);
        if (scopeChanged) {
          return AndroidGameStreamAuthorityV2(
            clientInstanceId: current.clientInstanceId,
            coreId: current.coreId,
            homeId: current.homeId,
            accountId: '9' * 32,
            familyId: '8' * 32,
            accountRevision: current.accountRevision,
            pinRevision: current.pinRevision,
            pinConfigured: current.pinConfigured,
            pinUnlocked: current.pinUnlocked,
            routeRevision: current.routeRevision,
            lifecycleRevision: current.lifecycleRevision,
            idleRevision: current.idleRevision,
            interactionRevision: current.interactionRevision,
          );
        }
        if (!drifted) return current;
        return AndroidGameStreamAuthorityV2(
          clientInstanceId: current.clientInstanceId,
          coreId: current.coreId,
          homeId: current.homeId,
          accountId: current.accountId,
          familyId: current.familyId,
          accountRevision: current.accountRevision,
          pinRevision: 2,
          pinConfigured: true,
          pinUnlocked: false,
          routeRevision: 99,
          lifecycleRevision: 99,
          idleRevision: 99,
          interactionRevision: 99,
        );
      }

      GameStreamClientController buildController() =>
          GameStreamClientController(
            core: CoreGameStreamApi(transport, session, isCurrent: () => true),
            native: AndroidGameStreamV2Port(),
            authority: authority,
            isCurrent: () => true,
            recoveryStore: GameStreamRecoveryStore(backend: recoveryBackend),
          );
      final controller = buildController();
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.selectHost(controller.state.hosts.single);
      await controller.selectApp(controller.state.apps.single);
      await controller.start();
      expect(controller.state.phase, GameStreamClientPhase.streaming);
      drifted = true;

      await controller.stop();

      expect(controller.state.phase, GameStreamClientPhase.ready);
      expect(hostReads, 2);
      expect(appReads, 2);
      expect(capabilityReads, 2);

      await controller.retire();
      drifted = false;
      final second = buildController();
      addTearDown(second.dispose);
      await second.initialize();
      await second.selectHost(second.state.hosts.single);
      await second.selectApp(second.state.apps.single);
      await second.start();
      await second.retire();
      expect(retiredEpochs, [1, 1]);

      final third = buildController();
      addTearDown(third.dispose);
      await third.initialize();
      await third.selectHost(third.state.hosts.single);
      await third.selectApp(third.state.apps.single);
      await third.start();
      failNativeRetire = true;
      await expectLater(
        third.retire(),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'authority_changed',
          ),
        ),
      );
      expect(coreRetireCalls, 3);
      expect(third.state.activeSession, isNull);
      expect(recoveryBackend.value, isNotNull);
      expect(recoveryBackend.value, contains('"nativeRetired":false'));

      failNativeRetire = false;
      scopeChanged = true;
      final loggedOut = buildController();
      await loggedOut.initialize();
      expect(loggedOut.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(
        loggedOut.state.errorCode,
        'native_fenced_original_scope_required',
      );
      expect(recoveryBackend.value, contains('"nativeRetired":true'));
      final nativeRetiresAfterLogout = retiredEpochs.length;
      loggedOut.dispose();

      scopeChanged = false;
      final originalScope = buildController();
      await originalScope.initialize();
      expect(originalScope.state.phase, GameStreamClientPhase.idle);
      expect(recoveryBackend.value, isNull);
      expect(retiredEpochs, hasLength(nativeRetiresAfterLogout));
      originalScope.dispose();

      final storageFault = buildController();
      await storageFault.initialize();
      await storageFault.selectHost(storageFault.state.hosts.single);
      await storageFault.selectApp(storageFault.state.apps.single);
      await storageFault.start();
      final retiresBeforeStorageFault = retiredEpochs.length;
      recoveryBackend.failRead = true;
      await expectLater(storageFault.retire(), throwsA(isA<StateError>()));
      recoveryBackend.failRead = false;
      expect(retiredEpochs, hasLength(retiresBeforeStorageFault + 1));
      expect(retiredEpochs.last, 1);
      expect(storageFault.state.activeSession, isNull);
      storageFault.dispose();

      final driftedCore = buildController();
      addTearDown(driftedCore.dispose);
      await driftedCore.initialize();
      await driftedCore.selectHost(driftedCore.state.hosts.single);
      await driftedCore.selectApp(driftedCore.state.apps.single);
      await driftedCore.start();
      coreSessionRetired = true;
      await driftedCore.stop();
      expect(driftedCore.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(driftedCore.state.errorCode, 'stop_session_retired');
      expect(nativeStopDispatches, 1);
      expect(retiredEpochs.last, 1);

      coreSessionRetired = false;
      final uncertainCleanup = buildController();
      await uncertainCleanup.initialize();
      await uncertainCleanup.selectHost(uncertainCleanup.state.hosts.single);
      await uncertainCleanup.selectApp(uncertainCleanup.state.apps.single);
      await uncertainCleanup.start();
      failCoreRetire = true;
      await uncertainCleanup.stop();
      expect(
        uncertainCleanup.state.phase,
        GameStreamClientPhase.outcomeUnknown,
      );
      expect(uncertainCleanup.state.errorCode, 'stop_cleanup_unknown');
      expect(uncertainCleanup.state.lastCommand?.state, 'native_observed');
      expect(recoveryBackend.value, isNotNull);
      expect(recoveryBackend.value, contains('"nativeRetired":true'));
      final stopsBeforeRecovery = nativeStopDispatches;
      final nativeRetiresBeforeRecovery = retiredEpochs.length;

      final coreRetiresBeforeLocalClose = coreRetireCalls;
      await uncertainCleanup.closeLocalSession();
      expect(
        uncertainCleanup.state.phase,
        GameStreamClientPhase.outcomeUnknown,
      );
      expect(uncertainCleanup.state.errorCode, 'local_session_cleanup_unknown');
      expect(uncertainCleanup.state.activeSession, isNotNull);
      expect(recoveryBackend.value, isNotNull);
      expect(nativeStopDispatches, stopsBeforeRecovery);
      expect(retiredEpochs, hasLength(nativeRetiresBeforeRecovery));
      expect(coreRetireCalls, coreRetiresBeforeLocalClose + 1);

      failCoreRetire = false;
      wrongCoreRetireId = true;
      await uncertainCleanup.closeLocalSession();
      expect(
        uncertainCleanup.state.phase,
        GameStreamClientPhase.outcomeUnknown,
      );
      expect(uncertainCleanup.state.errorCode, 'local_session_cleanup_unknown');
      expect(uncertainCleanup.state.activeSession?.id, '7' * 32);
      expect(recoveryBackend.value, isNotNull);
      expect(nativeStopDispatches, stopsBeforeRecovery);
      expect(retiredEpochs, hasLength(nativeRetiresBeforeRecovery));

      wrongCoreRetireId = false;
      await uncertainCleanup.closeLocalSession();
      expect(uncertainCleanup.state.phase, GameStreamClientPhase.idle);
      expect(uncertainCleanup.state.activeSession, isNull);
      expect(recoveryBackend.value, isNull);
      expect(nativeStopDispatches, stopsBeforeRecovery);
      expect(retiredEpochs, hasLength(nativeRetiresBeforeRecovery));
      uncertainCleanup.dispose();

      final recoveredCleanup = buildController();
      addTearDown(recoveredCleanup.dispose);
      await recoveredCleanup.initialize();
      expect(recoveredCleanup.state.phase, GameStreamClientPhase.idle);
      expect(recoveredCleanup.state.lastCommand, isNull);
      expect(recoveryBackend.value, isNull);
      expect(nativeStopDispatches, stopsBeforeRecovery);
      expect(retiredEpochs, hasLength(nativeRetiresBeforeRecovery));
    },
  );

  test(
    'pairing authority retirement survives callback loss, logout and restart',
    () async {
      final beginEntered = Completer<void>();
      final discovery = Completer<Map<String, Object?>>();
      var retireAttempts = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        switch (call.method) {
          case 'beginPairingV2':
            if (!beginEntered.isCompleted) beginEntered.complete();
            return discovery.future;
          case 'retireAuthorityV2':
            retireAttempts += 1;
            expect(args['requestId'], _pairingId);
            expect(args['nativeBindingId'], isNull);
            expect(args['bindingRevision'], isNull);
            final authority = Map<Object?, Object?>.from(
              args['authority']! as Map,
            );
            expect(authority['accountId'], 'c' * 32);
            return {
              'schemaVersion': 2,
              'requestId': _pairingId,
              'authorityId': 'a' * 32,
              'authorityEpoch': 2,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 1,
              'state': 'retired',
            };
          default:
            fail('unexpected native method ${call.method}');
        }
      });
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': <Object>[],
            });
          }
          if (request.method == 'POST' && path.endsWith('/pairings')) {
            return _response({
              'schemaVersion': 2,
              'id': _pairingId,
              'revision': 1,
              'state': 'pending',
              'pairingGrant': '2' * 32,
              'expiresAt': 1800000000.0,
            }, 201);
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      final backend = _MemoryRecoveryBackend();

      GameStreamClientController build(
        AndroidGameStreamAuthorityV2 Function(int) authority,
      ) => GameStreamClientController(
        core: CoreGameStreamApi(transport, session, isCurrent: () => true),
        native: AndroidGameStreamV2Port(),
        authority: authority,
        isCurrent: () => true,
        recoveryStore: GameStreamRecoveryStore(backend: backend),
        now: () => DateTime.utc(2026, 10, 1),
      );

      final first = build(_authority);
      await first.initialize();
      final pairing = first.beginPairing();
      await beginEntered.future;
      backend.failRead = true;
      await expectLater(first.retire(), throwsA(isA<StateError>()));
      backend.failRead = false;
      expect(backend.value, contains('"authorityRetirementPending":false'));
      expect(backend.value, contains('"authorityRetired":false'));
      discovery.complete({
        'schemaVersion': 2,
        'requestId': '9' * 32,
        'nativeBindingId': '4' * 32,
        'bindingRevision': 1,
        'engineRevision': 'moonlight-android-12.2-larenor-embed-v2',
        'provider': 'moonlight-nvhttp',
        'catalogRevision': 1,
        'catalogDigest': 'a' * 64,
        'candidates': <Object>[],
      });
      await pairing;
      first.dispose();

      AndroidGameStreamAuthorityV2 loggedOutAuthority(int revision) {
        final current = _authority(revision);
        return AndroidGameStreamAuthorityV2(
          clientInstanceId: current.clientInstanceId,
          coreId: current.coreId,
          homeId: current.homeId,
          accountId: '9' * 32,
          familyId: '8' * 32,
          accountRevision: current.accountRevision,
          pinRevision: current.pinRevision,
          pinConfigured: current.pinConfigured,
          pinUnlocked: current.pinUnlocked,
          routeRevision: 2,
          lifecycleRevision: 2,
          idleRevision: 2,
          interactionRevision: 2,
        );
      }

      final loggedOut = build(loggedOutAuthority);
      await loggedOut.initialize();
      expect(loggedOut.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(
        loggedOut.state.errorCode,
        'native_fenced_original_scope_required',
      );
      expect(backend.value, contains('"authorityRetired":true'));
      loggedOut.dispose();

      final original = build(_authority);
      addTearDown(original.dispose);
      await original.initialize();
      expect(original.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(original.state.errorCode, 'pairing_authority_retired');
      expect(retireAttempts, 2);
      expect(backend.value, contains('"pairingGrant":"${'2' * 32}"'));
    },
  );

  test('catalog authority is fenced with its exact stored binding', () async {
    var retireCalls = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'retireAuthorityV2');
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      retireCalls += 1;
      expect(args['requestId'], _catalogId);
      expect(args['nativeBindingId'], '4' * 32);
      expect(args['bindingRevision'], 3);
      return {
        'schemaVersion': 2,
        'requestId': _catalogId,
        'authorityId': 'a' * 32,
        'authorityEpoch': 2,
        'nativeBindingId': '4' * 32,
        'bindingRevision': 3,
        'state': 'retired',
      };
    });
    final backend = _MemoryRecoveryBackend();
    final store = GameStreamRecoveryStore(backend: backend);
    final authority = _authority(7);
    await store.writeAny(
      GameStreamCatalogRecovery(
        scope: GameStreamRecoveryScope(
          coreId: authority.coreId,
          homeId: authority.homeId,
          accountId: authority.accountId,
          familyId: authority.familyId,
        ),
        authority: authority,
        accountRevision: 7,
        observationId: _catalogId,
        observationRevision: 1,
        catalogGrant: '2' * 32,
        expiresAtMillis: 1800000000000,
        host: CoreGameStreamHost.fromJson(_host(1)),
        nativeBindingId: '4' * 32,
        bindingRevision: 3,
        registrationRevision: 4,
        engineRevision: 'moonlight-android-12.2-larenor-embed-v2',
      ).withCatalogDispatched(),
    );
    final session = _session();
    final transport = LarenorServerApi(
      endpoint: session.endpoint,
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, endsWith('/hosts'));
        return _response({
          'schemaVersion': 2,
          'scope': {'schemaVersion': 1, 'coreId': 'a' * 32, 'homeId': 'b' * 32},
          'accountRevision': 7,
          'hosts': <Object>[],
        });
      }),
    );
    addTearDown(transport.close);
    final controller = GameStreamClientController(
      core: CoreGameStreamApi(transport, session, isCurrent: () => true),
      native: AndroidGameStreamV2Port(),
      authority: (revision) {
        final current = _authority(revision);
        return AndroidGameStreamAuthorityV2(
          clientInstanceId: current.clientInstanceId,
          coreId: current.coreId,
          homeId: current.homeId,
          accountId: '9' * 32,
          familyId: '8' * 32,
          accountRevision: current.accountRevision,
          pinRevision: current.pinRevision,
          pinConfigured: current.pinConfigured,
          pinUnlocked: current.pinUnlocked,
          routeRevision: 2,
          lifecycleRevision: 2,
          idleRevision: 2,
          interactionRevision: 2,
        );
      },
      isCurrent: () => true,
      recoveryStore: store,
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.state.phase, GameStreamClientPhase.outcomeUnknown);
    expect(controller.state.errorCode, 'native_fenced_original_scope_required');
    expect(retireCalls, 1);
    expect(backend.value, contains('"catalogGrant":"${'2' * 32}"'));
    expect(backend.value, contains('"authorityRetired":true'));
  });

  test(
    'bind failure recovery retires the Core session without rebinding',
    () async {
      var bindCalls = 0;
      var executeCalls = 0;
      var retireCalls = 0;
      var nativeRetireCalls = 0;
      var nativeRetireAvailable = false;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final requestId = args['requestId'] as String?;
        switch (call.method) {
          case 'resolveBindingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 3,
              'registrationRevision': 4,
              'hostId': _hostId,
              'appId': _appId,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            };
          case 'sessionCapabilitiesV2':
            return _availableCapabilities(requestId!);
          case 'bindSessionV2':
            bindCalls += 1;
            throw PlatformException(code: 'bind_failed');
          case 'retire':
            nativeRetireCalls += 1;
            if (!nativeRetireAvailable) {
              throw PlatformException(code: 'channel_failure');
            }
            return {
              'schemaVersion': 2,
              'sessionId': args['sessionId'],
              'epoch': args['epoch'],
              'state': 'retired',
            };
          case 'executeV2':
            executeCalls += 1;
            fail('a failed bind must never execute');
          default:
            fail('unexpected native method ${call.method}');
        }
      });
      var cleanupAvailable = false;
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': [_host(1)],
            });
          }
          if (request.method == 'GET' && path.endsWith('/apps')) {
            return _response({
              'schemaVersion': 2,
              'hostRevision': 1,
              'pairingRevision': 1,
              'catalogRevision': 1,
              'apps': [_app()],
            });
          }
          if (request.method == 'POST' && path.endsWith('/sessions')) {
            return _response(_coreSession(), 201);
          }
          if (request.method == 'GET' && path.endsWith('/${'7' * 32}')) {
            return _response(_coreSession());
          }
          if (request.method == 'POST' && path.endsWith('/retire')) {
            retireCalls += 1;
            return cleanupAvailable
                ? _response(_coreSession(state: 'retired', revision: 2))
                : _response({'error': 'server_unavailable'}, 503);
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      final backend = _MemoryRecoveryBackend();
      GameStreamClientController buildController() =>
          GameStreamClientController(
            core: CoreGameStreamApi(transport, session, isCurrent: () => true),
            native: AndroidGameStreamV2Port(),
            authority: _authority,
            isCurrent: () => true,
            recoveryStore: GameStreamRecoveryStore(backend: backend),
          );

      final first = buildController();
      await first.initialize();
      await first.selectHost(first.state.hosts.single);
      await first.selectApp(first.state.apps.single);
      await first.start();
      expect(first.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(first.state.errorCode, 'session_bind_cleanup_unknown');
      expect(backend.value, isNotNull);
      expect(bindCalls, 1);
      expect(retireCalls, 1);
      first.dispose();

      nativeRetireAvailable = true;
      final fenced = buildController();
      await fenced.initialize();
      expect(fenced.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(fenced.state.errorCode, 'session_bind_cleanup_unknown');
      expect(backend.value, isNotNull);
      expect(backend.value, contains('"nativeRetired":true'));
      expect(retireCalls, 2);
      expect(nativeRetireCalls, 2);
      fenced.dispose();

      cleanupAvailable = true;
      final recovered = buildController();
      addTearDown(recovered.dispose);
      await recovered.initialize();
      expect(recovered.state.phase, GameStreamClientPhase.idle);
      expect(backend.value, isNull);
      expect(bindCalls, 1);
      expect(executeCalls, 0);
      expect(retireCalls, 3);
      expect(nativeRetireCalls, 2);
    },
  );

  test(
    'retired Core command recovery keeps the grant until native fencing',
    () async {
      var nativeRetireAvailable = false;
      var nativeRetireCalls = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        if (call.method != 'retire') {
          fail('retired command recovery must not call ${call.method}');
        }
        nativeRetireCalls += 1;
        expect(args['sessionId'], '7' * 32);
        expect(args['epoch'], 1);
        if (!nativeRetireAvailable) {
          throw PlatformException(code: 'channel_failure');
        }
        return {
          'schemaVersion': 2,
          'sessionId': '7' * 32,
          'epoch': 1,
          'state': 'retired',
        };
      });
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': [_host(1)],
            });
          }
          if (request.method == 'GET' && path.endsWith('/${'7' * 32}')) {
            return _response(_coreSession(state: 'retired', revision: 2));
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      final backend = _MemoryRecoveryBackend();
      final store = GameStreamRecoveryStore(backend: backend);
      await store.write(
        GameStreamRecoveryRecord(
          scope: _recoveryScopeForTest(),
          sessionId: '7' * 32,
          sessionRevision: 1,
          commandId: '4' * 32,
          intent: 'stream',
          dispatchGrant: '5' * 32,
        ),
      );
      GameStreamClientController buildController() =>
          GameStreamClientController(
            core: CoreGameStreamApi(transport, session, isCurrent: () => true),
            native: AndroidGameStreamV2Port(),
            authority: _authority,
            isCurrent: () => true,
            recoveryStore: store,
          );

      final first = buildController();
      await first.initialize();
      expect(first.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(first.state.errorCode, 'native_retirement_unknown');
      expect(backend.value, isNotNull);
      first.dispose();

      nativeRetireAvailable = true;
      final fenced = buildController();
      addTearDown(fenced.dispose);
      await fenced.initialize();
      expect(fenced.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(fenced.state.errorCode, 'recovered_session_retired');
      expect(backend.value, isNull);
      expect(nativeRetireCalls, 2);
    },
  );

  test(
    'terminal stop recovery transitions to cleanup without command replay',
    () async {
      var nativeRetireCalls = 0;
      var coreRetireCalls = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        if (call.method != 'retire') {
          fail('terminal stop recovery must not call ${call.method}');
        }
        nativeRetireCalls += 1;
        return {
          'schemaVersion': 2,
          'sessionId': args['sessionId'],
          'epoch': args['epoch'],
          'state': 'retired',
        };
      });
      final session = _session();
      final transport = LarenorServerApi(
        endpoint: session.endpoint,
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path.endsWith('/hosts')) {
            return _response({
              'schemaVersion': 2,
              'scope': {
                'schemaVersion': 1,
                'coreId': 'a' * 32,
                'homeId': 'b' * 32,
              },
              'accountRevision': 7,
              'hosts': [_host(1)],
            });
          }
          if (request.method == 'GET' && path.endsWith('/${'7' * 32}')) {
            return _response(_coreSession());
          }
          if (request.method == 'GET' && path.endsWith('/${'4' * 32}')) {
            return _response(
              _coreCommand('4' * 32, 'stop', state: 'native_observed'),
            );
          }
          if (request.method == 'POST' && path.endsWith('/retire')) {
            coreRetireCalls += 1;
            return _response(_coreSession(state: 'retired', revision: 2));
          }
          fail('unexpected Core request ${request.method} $path');
        }),
      );
      addTearDown(transport.close);
      final backend = _MemoryRecoveryBackend();
      final store = GameStreamRecoveryStore(backend: backend);
      await store.write(
        GameStreamRecoveryRecord(
          scope: _recoveryScopeForTest(),
          sessionId: '7' * 32,
          sessionRevision: 1,
          commandId: '4' * 32,
          intent: 'stop',
          dispatchGrant: '5' * 32,
        ),
      );
      final controller = GameStreamClientController(
        core: CoreGameStreamApi(transport, session, isCurrent: () => true),
        native: AndroidGameStreamV2Port(),
        authority: _authority,
        isCurrent: () => true,
        recoveryStore: store,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.state.phase, GameStreamClientPhase.idle);
      expect(controller.state.lastCommand?.state, 'native_observed');
      expect(controller.state.lastCommand?.result, 'stopped');
      expect(backend.value, isNull);
      expect(nativeRetireCalls, 1);
      expect(coreRetireCalls, 1);
    },
  );
}

GameStreamRecoveryScope _recoveryScopeForTest() => GameStreamRecoveryScope(
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  accountId: 'c' * 32,
  familyId: 'f' * 32,
);
