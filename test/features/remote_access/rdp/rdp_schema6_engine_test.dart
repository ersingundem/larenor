import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

const pin = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final class RecordingMethods extends MethodChannel {
  RecordingMethods(this.handler) : super('schema6-test');
  final Future<Object?> Function(String method, Object? arguments) handler;
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async =>
      await handler(method, arguments) as T?;
}

RdpGatewayEndpoint endpoint(String host, {String domain = ''}) =>
    RdpGatewayEndpoint(host: host, port: 443, username: 'user', domain: domain);

final transferAuthority = RdpFileTransferAuthority(
  namespaceDigest: ''.padLeft(64, 'a'),
  profileRef: ''.padLeft(64, 'b'),
  profileRevision: 4,
);
const transferGrant = RdpFileTransferGrant(
  id: '0123456789abcdef0123456789abcdef',
  revision: 7,
);
final transferOwner = RdpSchema6SessionOwner(
  requestId: '12345678-1234-4234-9234-123456789abc',
  revision: 9,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'stage one sends no password and validates exact gateway receipt',
    () async {
      Map? captured;
      final engine = RdpSchema6MethodChannelGatewayEngine(
        methods: RecordingMethods((method, arguments) async {
          expect(method, 'inspectGateway');
          captured = arguments as Map;
          return {
            'schemaVersion': 6,
            'requestId': captured!['requestId'],
            'kind': 'gateway',
            'certificateFingerprint': pin,
          };
        }),
        random: Random(1),
      );
      final result = await engine.inspectGateway(
        target: endpoint('target.example'),
        gateway: endpoint('gateway.example', domain: 'EDGE'),
        isCurrent: () => true,
      );
      expect(result.kind, RdpGatewayCertificateKind.gateway);
      expect(captured!.keys, {
        'schemaVersion',
        'requestId',
        'target',
        'gateway',
      });
      expect((captured!['target'] as Map).containsKey('domain'), isFalse);
      expect((captured!['gateway'] as Map)['domain'], 'EDGE');
      expect(captured.toString(), isNot(contains('password')));
    },
  );

  test('stage two sends one byte buffer and wipes it after reply', () async {
    late Uint8List sent;
    final secret = RdpOwnedSecretBuffer(Uint8List.fromList([9, 8, 7]));
    final engine = RdpSchema6MethodChannelGatewayEngine(
      methods: RecordingMethods((method, arguments) async {
        expect(method, 'inspectTargetThroughGateway');
        final value = arguments as Map;
        sent = value['gatewayPassword'] as Uint8List;
        expect(sent, [9, 8, 7]);
        expect((value['gateway'] as Map)['certificateFingerprint'], pin);
        return {
          'schemaVersion': 6,
          'requestId': value['requestId'],
          'kind': 'target',
          'certificateFingerprint': pin,
        };
      }),
      random: Random(2),
    );
    final result = await engine.inspectTargetThroughGateway(
      target: endpoint('target.example', domain: 'TARGET'),
      gateway: RdpPinnedGatewayEndpoint(
        endpoint: endpoint('gateway.example', domain: 'EDGE'),
        fingerprint: pin,
      ),
      gatewayPassword: secret,
      isCurrent: () => true,
    );
    expect(result.kind, RdpGatewayCertificateKind.target);
    expect(sent, [0, 0, 0]);
    expect(secret.bytes, [0, 0, 0]);
  });

  test('retirement cancels and rejects a late enrollment result', () async {
    final pending = Completer<Object?>();
    final methods = <String>[];
    final engine = RdpSchema6MethodChannelGatewayEngine(
      methods: RecordingMethods((method, arguments) async {
        methods.add(method);
        if (method == 'cancel') return null;
        return pending.future;
      }),
      random: Random(3),
    );
    var current = true;
    final future = engine.inspectGateway(
      target: endpoint('target.example'),
      gateway: endpoint('gateway.example'),
      isCurrent: () => current,
    );
    current = false;
    engine.close();
    pending.complete({
      'schemaVersion': 6,
      'requestId': 'not-used-after-retirement',
      'kind': 'gateway',
      'certificateFingerprint': pin,
    });
    await expectLater(future, throwsA(isA<RdpFailure>()));
    await Future<void>.delayed(Duration.zero);
    expect(methods, contains('cancel'));
  });

  test('timeout is bounded and fixed platform errors are mapped', () async {
    final timed = RdpSchema6MethodChannelGatewayEngine(
      methods: RecordingMethods((method, arguments) async {
        if (method == 'cancel') return null;
        return Completer<Object?>().future;
      }),
      deadline: const Duration(milliseconds: 1),
    );
    await expectLater(
      timed.inspectGateway(
        target: endpoint('target.example'),
        gateway: endpoint('gateway.example'),
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having((value) => value.code, 'code', 'timed_out'),
      ),
    );

    final failed = RdpSchema6MethodChannelGatewayEngine(
      methods: RecordingMethods((method, arguments) async {
        throw PlatformException(code: 'foregroundRequired');
      }),
    );
    await expectLater(
      failed.inspectGateway(
        target: endpoint('target.example'),
        gateway: endpoint('gateway.example'),
        isCurrent: () => true,
      ),
      throwsA(
        isA<RdpFailure>().having(
          (value) => value.code,
          'code',
          'foreground_required',
        ),
      ),
    );
  });

  test('timeout remains bounded when native cancel never replies', () async {
    final engine = RdpSchema6MethodChannelGatewayEngine(
      methods: RecordingMethods(
        (method, arguments) => Completer<Object?>().future,
      ),
      deadline: const Duration(milliseconds: 1),
    );
    await expectLater(
      engine
          .inspectGateway(
            target: endpoint('target.example'),
            gateway: endpoint('gateway.example'),
            isCurrent: () => true,
          )
          .timeout(const Duration(seconds: 2)),
      throwsA(
        isA<RdpFailure>().having((value) => value.code, 'code', 'timed_out'),
      ),
    );
  });

  test(
    'transfer adapter binds exact authority grant and public owner',
    () async {
      late Map<Object?, Object?> sent;
      final port = RdpSchema6MethodChannelTransferPort(
        methods: RecordingMethods((method, arguments) async {
          expect(method, 'prepareFileTransfer');
          sent = Map<Object?, Object?>.from(arguments! as Map);
          return {
            'schemaVersion': 6,
            'requestId': sent['requestId'],
            'authorityId': transferAuthority.authorityId,
            'grantId': transferGrant.id,
            'grantRevision': transferGrant.revision,
            'transferId': 'fedcba9876543210fedcba9876543210',
            'state': 'prepared',
          };
        }),
        random: Random(5),
      );
      final result = await port.prepare(
        authority: transferAuthority,
        grant: transferGrant,
        sessionOwner: transferOwner,
        isCurrent: () => true,
      );
      expect(result.state, RdpTransferState.prepared);
      expect(sent.keys, {
        'schemaVersion',
        'requestId',
        'authority',
        'grantId',
        'grantRevision',
        'sessionRequestId',
        'sessionRevision',
      });
      expect(sent['sessionRequestId'], transferOwner.requestId);
      expect(sent['sessionRevision'], transferOwner.revision);
      expect(sent.toString(), isNot(contains('content://')));
    },
  );

  test('drain timeout stays uncertain and is never replayed', () async {
    var calls = 0;
    final port = RdpSchema6MethodChannelTransferPort(
      methods: RecordingMethods((method, arguments) {
        calls += 1;
        return Completer<Object?>().future;
      }),
      deadline: const Duration(milliseconds: 1),
    );
    await expectLater(
      port.drain(
        authority: transferAuthority,
        grant: transferGrant,
        transferId: 'fedcba9876543210fedcba9876543210',
        sessionOwner: transferOwner,
        isCurrent: () => false,
      ),
      throwsA(
        isA<RdpFailure>().having((value) => value.code, 'code', 'timed_out'),
      ),
    );
    expect(calls, 1);
  });
}
