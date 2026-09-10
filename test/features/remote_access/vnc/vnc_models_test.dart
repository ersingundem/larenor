import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/vnc/vnc_models.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(File('contracts/vnc-client.v1.json').readAsStringSync())
        as Map<String, dynamic>;

const profile = RemoteProfile(
  id: 'a0000000000000000000000000000001',
  name: 'Studio screen',
  protocol: RemoteProtocol.vnc,
  host: 'screen.home.arpa',
  port: 5900,
);

void main() {
  test('strict capabilities distinguish unavailable and secure RFB', () {
    final data = fixture();
    final available = VncCapabilities.fromJson(data['availableCapabilities']);
    final unavailable = VncCapabilities.fromJson(
      data['unavailableCapabilities'],
    );
    expect(available.canConnect, isTrue);
    expect(available.supportedVersions, {RfbProtocolVersion.v38});
    expect(
      available.supportedSecurity,
      {RfbSecurityType.vencryptTlsVncAuth},
    );
    expect(unavailable.canConnect, isFalse);
    expect(unavailable.engineRevision, isNull);
    expect(
      () => VncCapabilities.fromJson({
        ...data['availableCapabilities'] as Map,
        'futureCapability': true,
      }),
      throwsA(isA<VncFailure>()),
    );
  });

  test('secure negotiation requires RFB 3.8 and a valid SPKI pin', () {
    final secure = RfbNegotiation.fromJson(fixture()['secureNegotiation']);
    secure.validate(VncTransportPolicy.lockedDown);
    expect(secure.tls, isTrue);
    expect(secure.certificate, isNotNull);

    final invalid = Map<String, dynamic>.from(
      fixture()['secureNegotiation'] as Map,
    )..['certificate'] = {
        'algorithm': 'sha1',
        'fingerprint': 'secret',
      };
    expect(
      () => RfbNegotiation.fromJson(invalid),
      throwsA(isA<VncFailure>()),
    );
  });

  test('plain VNC and no-auth negotiation are rejected by default', () {
    final plain = RfbNegotiation.fromJson(fixture()['plainNegotiation']);
    expect(
      () => plain.validate(VncTransportPolicy.lockedDown),
      throwsA(
        isA<VncFailure>().having(
          (value) => value.code,
          'code',
          'plain_vnc_rejected',
        ),
      ),
    );
    final noAuth = Map<String, dynamic>.from(
      fixture()['plainNegotiation'] as Map,
    )
      ..['securityType'] = 'none'
      ..['requiresPassword'] = false;
    expect(
      () => RfbNegotiation.fromJson(noAuth)
          .validate(VncTransportPolicy.lockedDown),
      throwsA(isA<VncFailure>()),
    );
  });

  test('session defaults deny clipboard/files and bound DeX display', () {
    const request = VncSessionRequest(
      profile: profile,
      display: VncDisplaySpec(
        width: 2560,
        height: 1600,
        dpi: 220,
        externalDisplay: true,
      ),
      securityType: RfbSecurityType.vencryptTlsVncAuth,
      certificateFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(request.channels, VncChannelPolicy.lockedDown);
    expect(request.channels.clipboard, isFalse);
    expect(request.channels.files, isFalse);
    expect(request.display.pixelCount, 4096000);
    request.validate(
      VncCapabilities.fromJson(fixture()['availableCapabilities']),
    );
  });

  test('password lease redacts, consumes once, and wipes owned bytes', () {
    const password = 'plain-text-must-not-escape';
    final secret = VncEphemeralSecret.fromText(password);
    expect(secret.toString(), isNot(contains(password)));
    final lease = secret.consume();
    expect(utf8.decode(lease.bytes), password);
    lease.dispose();
    expect(lease.bytes, everyElement(0));
    expect(() => secret.consume(), throwsA(isA<VncFailure>()));
  });
}
