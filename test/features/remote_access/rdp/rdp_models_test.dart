import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';

Map<String, dynamic> fixture() => jsonDecode(
  File('contracts/rdp-client.v1.json').readAsStringSync(),
) as Map<String, dynamic>;

const profile = RemoteProfile(
  id: 'a0000000000000000000000000000001',
  name: 'Office PC',
  protocol: RemoteProtocol.rdp,
  host: 'desktop.home.arpa',
  port: 3389,
  username: 'ersin',
);

void main() {
  test('strict capabilities distinguish unavailable and secure RDP', () {
    final f = fixture();
    final available = RdpCapabilities.fromJson(f['availableCapabilities']);
    final unavailable = RdpCapabilities.fromJson(
      f['unavailableCapabilities'],
    );
    expect(available.canConnect, isTrue);
    expect(available.supportsNla, isTrue);
    expect(available.supportsExternalDisplay, isTrue);
    expect(unavailable.canConnect, isFalse);
    expect(unavailable.engineRevision, isNull);
    expect(
      () => RdpCapabilities.fromJson({
        ...f['availableCapabilities'] as Map,
        'futureCapability': true,
      }),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('session defaults deny clipboard audio and files', () {
    const request = RdpSessionRequest(
      profile: profile,
      display: RdpDisplaySpec(
        width: 2560,
        height: 1600,
        dpi: 220,
        externalDisplay: true,
      ),
      certificateFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(request.channels, RdpChannelPolicy.lockedDown);
    expect(request.channels.clipboard, isFalse);
    expect(request.channels.audio, isFalse);
    expect(request.channels.files, isFalse);
    expect(request.display.pixelCount, 4096000);
    request.validate(RdpCapabilities.fromJson(fixture()['availableCapabilities']));
  });

  test('display capability and insecure requests fail closed', () {
    final capabilities = RdpCapabilities.fromJson(
      fixture()['availableCapabilities'],
    );
    for (final display in [
      const RdpDisplaySpec(width: 639, height: 768, dpi: 220),
      const RdpDisplaySpec(width: 1920, height: 1080, dpi: 641),
      const RdpDisplaySpec(width: 9000, height: 1080, dpi: 220),
    ]) {
      expect(
        () => RdpSessionRequest(
          profile: profile,
          display: display,
          certificateFingerprint:
              'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ).validate(capabilities),
        throwsA(isA<RdpFailure>()),
      );
    }
    expect(
      () => RdpSessionRequest(
        profile: RemoteProfile(
          id: profile.id,
          name: profile.name,
          protocol: RemoteProtocol.ssh,
          host: profile.host,
          port: 22,
          username: profile.username,
        ),
        display: const RdpDisplaySpec(width: 1920, height: 1080, dpi: 220),
        certificateFingerprint: 'not-a-pin',
      ).validate(capabilities),
      throwsA(isA<RdpFailure>()),
    );
  });
}
