import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_security_namespace.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';

void main() {
  test('local and Core namespace digests preserve SSH v2 bytes exactly', () {
    expect(
      RemoteSecurityNamespace.local().digest,
      '0d8047307e98c06ec682dab232f84a5dbdb4c041e79c0f9b4a6f63339ebc0747',
    );
    expect(
      RemoteSecurityNamespace.coreManaged(
        endpoint: 'https://core.example/',
        coreId: '1' * 32,
        homeId: '2' * 32,
        accountId: '3' * 32,
        sessionFamilyId: '4' * 32,
      ).digest,
      'e4b98c8a344a0d379989bbb01d5f3e4ae2dc254effc4b79db2a22f9b0f6f9e22',
    );
    expect(
      SshSecurityNamespace.local().digest,
      '0d8047307e98c06ec682dab232f84a5dbdb4c041e79c0f9b4a6f63339ebc0747',
    );
    expect(
      SshSecurityNamespace.coreManaged(
        endpoint: 'https://core.example/',
        coreId: '1' * 32,
        homeId: '2' * 32,
        accountId: '3' * 32,
        sessionFamilyId: '4' * 32,
      ).digest,
      'e4b98c8a344a0d379989bbb01d5f3e4ae2dc254effc4b79db2a22f9b0f6f9e22',
    );
  });

  test('Core namespace requires one exact normalized authority source', () {
    for (final endpoint in [
      'http://',
      'ftp://core.example/',
      'https://user@core.example/',
      'https://core.example/?query=1',
      'https://CORE.example/',
    ]) {
      expect(
        () => RemoteSecurityNamespace.coreManaged(
          endpoint: endpoint,
          coreId: '1' * 32,
          homeId: '2' * 32,
          accountId: '3' * 32,
          sessionFamilyId: '4' * 32,
        ),
        throwsFormatException,
      );
    }
  });
}
