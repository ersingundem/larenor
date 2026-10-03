import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_schema6_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

const pin = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  test('gateway observation is exact and request bound', () {
    expect(
      () =>
          RdpGatewayEndpoint(host: 'gateway.example', port: 443, username: ''),
      throwsA(isA<RdpFailure>()),
    );
    final value = RdpGatewayCertificateObservation.fromWire(
      const {
        'schemaVersion': 6,
        'requestId': 'request-1',
        'kind': 'gateway',
        'certificateFingerprint': pin,
      },
      requestId: 'request-1',
      kind: RdpGatewayCertificateKind.gateway,
    );
    expect(value.certificate.fingerprint, pin);
    for (final changed in [
      {
        'schemaVersion': 6,
        'requestId': 'other',
        'kind': 'gateway',
        'certificateFingerprint': pin,
      },
      {
        'schemaVersion': 6,
        'requestId': 'request-1',
        'kind': 'target',
        'certificateFingerprint': pin,
      },
      {
        'schemaVersion': 6,
        'requestId': 'request-1',
        'kind': 'gateway',
        'certificateFingerprint': pin,
        'host': 'private.example',
      },
    ]) {
      expect(
        () => RdpGatewayCertificateObservation.fromWire(
          changed,
          requestId: 'request-1',
          kind: RdpGatewayCertificateKind.gateway,
        ),
        throwsA(isA<RdpFailure>()),
      );
    }
  });

  test('Core security projection rejects secrets and missing public facts', () {
    final value = RdpCoreSecurityProjection.fromJson(const {
      'domain': 'LARENOR',
      'certificateFingerprint': pin,
      'gateway': {
        'host': 'gateway.example',
        'port': 443,
        'username': 'gateway-user',
        'domain': 'EDGE',
        'certificateFingerprint': pin,
      },
    });
    expect(value.gateway!.endpoint.host, 'gateway.example');
    expect(value.gateway!.endpoint.domain, 'EDGE');
    expect(value.toJson(), const {
      'domain': 'LARENOR',
      'certificateFingerprint': pin,
      'gateway': {
        'host': 'gateway.example',
        'port': 443,
        'username': 'gateway-user',
        'domain': 'EDGE',
        'certificateFingerprint': pin,
      },
    });
    expect(
      () => RdpCoreSecurityProjection.fromJson(const {
        'domain': 'LARENOR',
        'certificateFingerprint': pin,
        'gatewayPassword': 'forbidden',
        'gateway': null,
      }),
      throwsA(isA<RdpFailure>()),
    );
    expect(
      () => RdpCoreSecurityProjection.fromJson(const {
        'domain': 'LARENOR',
        'certificateFingerprint': pin,
        'gateway': {
          'host': 'gateway.example',
          'port': 443,
          'username': 'gateway-user',
          'domain': 'EDGE',
        },
      }),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('transfer receipt binds authority grant request and opaque id', () {
    final authority = RdpFileTransferAuthority(
      namespaceDigest: 'a' * 64,
      profileRef: 'b' * 64,
      profileRevision: 7,
    );
    const grant = RdpFileTransferGrant(
      id: '0123456789abcdef0123456789abcdef',
      revision: 3,
    );
    final raw = {
      'schemaVersion': 6,
      'requestId': 'request-2',
      'authorityId': authority.authorityId,
      'grantId': grant.id,
      'grantRevision': grant.revision,
      'transferId': 'fedcba9876543210fedcba9876543210',
      'state': 'prepared',
    };
    final value = RdpTransferReceipt.fromWire(
      raw,
      requestId: 'request-2',
      authority: authority,
      grant: grant,
      allowedStates: const {RdpTransferState.prepared},
    );
    expect(value.state, RdpTransferState.prepared);
    expect(value.toString(), isNot(contains(value.transferId)));
    expect(
      () => RdpSchema6SessionOwner(requestId: 'not-a-uuid', revision: 1),
      throwsA(isA<RdpFailure>()),
    );
    expect(
      () => RdpTransferReceipt.fromWire(
        {...raw, 'canonicalRoot': '/private/path'},
        requestId: 'request-2',
        authority: authority,
        grant: grant,
      ),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('owned secret buffer is one use and wipeable', () {
    final value = RdpOwnedSecretBuffer(Uint8List.fromList([1, 2, 3]));
    expect(value.take(), [1, 2, 3]);
    expect(() => value.take(), throwsA(isA<RdpFailure>()));
    value.wipe();
    expect(value.bytes, [0, 0, 0]);
  });
}
