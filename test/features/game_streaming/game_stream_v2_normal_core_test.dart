import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_v2_port.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';
import 'package:larenor/features/game_streaming/data/game_stream_client_controller.dart';
import 'package:larenor/features/game_streaming/data/game_stream_recovery_store.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _channel = MethodChannel('com.ersingundem.larenor/game-stream-native');

final class _SessionStore implements ServerSessionPersistence {
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _RecoveryBackend implements GameStreamRecoveryBackend {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String next) async => value = next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final coreUrl = Platform.environment['LARENOR_F60_CORE_URL'] ?? '';

  setUpAll(() => HttpOverrides.global = null);

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test(
    'real Client uses normal Core for pair stream stop and revoke',
    () async {
      final sessionStore = _SessionStore();
      final account = ServerAccountController(store: sessionStore);
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'F60 Client acceptance',
      );
      expect(account.failure, isNull);
      final session = account.session!;
      final context = session.context!;
      final familyId = session.sessionFamilyId!;
      var nativeDispatches = 0;
      var catalogDispatches = 0;
      var catalogReconcileTerminal = false;
      var registrationRevision = 1;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final requestId = args['requestId'] as String?;
        if (call.method != 'retire') {
          final authority = Map<Object?, Object?>.from(
            args['authority']! as Map,
          );
          expect(authority['pinConfigured'], isTrue);
          expect(authority['pinUnlocked'], isTrue);
        }
        switch (call.method) {
          case 'beginPairingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 1,
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
              'provider': 'moonlight-nvhttp',
              'catalogRevision': 1,
              'catalogDigest': 'a' * 64,
              'candidates': [
                {
                  'candidateId': '5' * 32,
                  'revision': 1,
                  'name': 'Owned Sunshine fixture',
                  'powerState': 'awake',
                  'pairState': 'notPaired',
                },
              ],
            };
          case 'pairHostV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'pairingId': args['pairingId'],
              'state': 'paired',
              'nativeReceiptDigest': 'd' * 64,
              'observation': {
                'schemaVersion': 1,
                'receiptId': '3' * 32,
                'nativeBindingId': '4' * 32,
                'bindingRevision': 1,
                'engineRevision': 'moonlight-12.2-b48494cb',
                'provider': 'moonlight-nvhttp',
                'state': 'paired',
                'hostObservationId': '5' * 32,
                'name': 'Owned Sunshine fixture',
                'codecs': ['h264', 'hevc'],
                'catalogRevision': 1,
                'catalogDigest': '4eaae18527a9abd5af0dbb06fed83156f9772e2340fb1a08065b2129248bf81f',
                'apps': [
                  {'observationId': '6' * 32, 'revision': 1, 'name': 'Desktop'},
                ],
              },
            };
          case 'commitRegistrationV2':
            final apps = args['apps']! as List;
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'registrationRevision': registrationRevision++,
              'hostId': (args['host']! as Map)['id'],
              'appIds': apps
                  .map((value) => (value as Map)['id'])
                  .toList(growable: false),
              'nativeReceiptDigest': 'e' * 64,
            };
          case 'resolveHostBindingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 1,
              'registrationRevision': 1,
              'hostId': args['hostId'],
              'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            };
          case 'readCatalogV2':
            catalogDispatches += 1;
            throw PlatformException(code: 'callback_lost');
          case 'reconcileV2':
            expect(args['operationKind'], 'catalog');
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'operationKind': 'catalog',
              'terminal': catalogReconcileTerminal,
              'receipt': catalogReconcileTerminal
                  ? {
                      'schemaVersion': 2,
                      'requestId': requestId,
                      'catalogObservationId': args['operationId'],
                      'state': 'observed',
                      'nativeReceiptDigest': '9' * 64,
                      'observation': {
                        'schemaVersion': 1,
                        'receiptId': '14141414141414141414141414141414',
                        'nativeBindingId': '4' * 32,
                        'bindingRevision': 1,
                        'catalogRevision': 2,
                        'catalogDigest': '4fd32d1a5a5611c9fb4b5fb3fde8ee7e1fb285a0b41f866df8eff0a87c4e8e3b',
                        'apps': [
                          {
                            'observationId': '6' * 32,
                            'revision': 2,
                            'name': 'Desktop updated',
                          },
                          {
                            'observationId': '7' * 32,
                            'revision': 1,
                            'name': 'New game',
                          },
                        ],
                      },
                    }
                  : null,
            };
          case 'configureStreamPolicyV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'policyId': 'c' * 32,
              'policyRevision': 8,
            };
          case 'resolveBindingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': '4' * 32,
              'bindingRevision': 1,
              'registrationRevision': 1,
              'hostId': args['hostId'],
              'appId': args['appId'],
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
          case 'bindSessionV2':
            return null;
          case 'executeV2':
            nativeDispatches += 1;
            final command = Map<Object?, Object?>.from(args['command']! as Map);
            final stop = command['intent'] == 'stop';
            if (stop) {
              expect(args['safetyClosure'], {
                'nativeBindingId': '4' * 32,
                'bindingRevision': 1,
              });
            } else {
              expect(args.keys, isNot(contains('safetyClosure')));
            }
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'sessionId': args['sessionId'],
              'commandId': command['id'],
              'state': 'native_observed',
              'result': stop ? 'stopped' : 'streaming',
              'observationKind': stop
                  ? 'connectionStopped'
                  : 'connectionStarted',
              'readbackRevision': nativeDispatches,
              'nativeReceiptDigest': stop ? '2' * 64 : '1' * 64,
            };
          case 'foregroundLeaseV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'nativeBindingId': args['nativeBindingId'],
              'bindingRevision': args['expectedBindingRevision'],
              'sessionId': args['sessionId'],
              'sessionRevision': args['expectedSessionRevision'],
              'owned': true,
              'state': 'game_visible',
            };
          case 'revokePairingV2':
            return {
              'schemaVersion': 2,
              'requestId': requestId,
              'revocationId': args['revocationId'],
              'state': 'local_cleared',
              'readbackRevision': 3,
              'nativeReceiptDigest': 'f' * 64,
            };
          case 'retire':
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

      final transport = LarenorServerApi(endpoint: session.endpoint);
      addTearDown(transport.close);
      final recoveryBackend = _RecoveryBackend();
      GameStreamClientController buildController() =>
          GameStreamClientController(
            core: CoreGameStreamApi(
              transport,
              session,
              isCurrent: () => identical(account.session, session),
            ),
            native: AndroidGameStreamV2Port(),
            authority: (accountRevision) => AndroidGameStreamAuthorityV2(
              clientInstanceId: '0' * 32,
              coreId: context.coreId,
              homeId: context.homeId,
              accountId: session.user.id,
              familyId: familyId,
              accountRevision: accountRevision,
              pinRevision: 1,
              pinConfigured: true,
              pinUnlocked: true,
              routeRevision: 1,
              lifecycleRevision: 1,
              idleRevision: 1,
              interactionRevision: 1,
            ),
            isCurrent: () => identical(account.session, session),
            recoveryStore: GameStreamRecoveryStore(backend: recoveryBackend),
            now: () => DateTime.fromMillisecondsSinceEpoch(
              int.parse(Platform.environment['LARENOR_F60_NOW_MS']!),
              isUtc: true,
            ),
          );

      final first = buildController();
      await first.initialize();
      expect(first.state.errorCode, isNull);
      await first.beginPairing();
      expect(
        first.state.candidates,
        hasLength(1),
        reason: first.state.errorCode,
      );
      await first.pair(first.state.candidates.single);
      expect(first.state.apps, hasLength(1), reason: first.state.errorCode);
      await first.refreshCatalog();
      expect(first.state.phase, GameStreamClientPhase.outcomeUnknown);
      expect(catalogDispatches, 1);
      first.dispose();

      catalogReconcileTerminal = true;
      final controller = buildController();
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(
        controller.state.apps,
        hasLength(2),
        reason: controller.state.errorCode,
      );
      expect(catalogDispatches, 1);
      await controller.configurePolicy(
        AndroidGameStreamPolicyDraft(
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
        ),
      );
      await controller.selectApp(controller.state.apps.first);
      expect(controller.state.capabilities?.available, isTrue);
      await controller.start();
      expect(controller.state.phase, GameStreamClientPhase.streaming);
      expect(
        await controller.foregroundCoverage(),
        AndroidGameStreamForegroundCoverage.game,
      );
      await controller.stop();
      expect(controller.state.phase, GameStreamClientPhase.ready);
      await controller.revoke(controller.state.selectedHost!);
      expect(controller.state.hosts, isEmpty);
      expect(nativeDispatches, 2);
    },
    skip: coreUrl.isEmpty
        ? 'Run with server/tests/support/f60_flutter_acceptance.py'
        : false,
  );
}
