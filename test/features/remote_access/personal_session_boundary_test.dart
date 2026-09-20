import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/presentation/personal_session_boundary.dart';

RemoteProfile profile(RemoteProtocol protocol) => RemoteProfile(
  id: '0123456789abcdef0123456789abcdef',
  name: 'Private target',
  protocol: protocol,
  host: 'secret.internal.example',
  port: remoteDefaultPort(protocol),
  username: 'private-user',
);

void main() {
  test('device-personal resource policy is closed and protocol bounded', () {
    expect(PersonalSessionPolicy.allowedFor(RemoteProtocol.ssh), {
      PersonalSessionResource.sshTerminal,
      PersonalSessionResource.sftpFiles,
      PersonalSessionResource.sshTunnel,
    });
    expect(PersonalSessionPolicy.allowedFor(RemoteProtocol.rdp), {
      PersonalSessionResource.desktop,
    });
    expect(PersonalSessionPolicy.allowedFor(RemoteProtocol.vnc), {
      PersonalSessionResource.desktop,
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final account = container.read(personalRemoteAccountProvider);
    expect(
      PersonalSessionLease.capture(
        account: account,
        routeIdentity: Object(),
        profile: profile(RemoteProtocol.rdp),
        profileRevision: 2,
        resource: PersonalSessionResource.sshTerminal,
        issuedAt: DateTime.utc(2026),
      ),
      isNull,
    );
    expect(
      PersonalSessionLease.capture(
        account: account,
        routeIdentity: Object(),
        profile: profile(RemoteProtocol.ssh),
        profileRevision: 2,
        resource: PersonalSessionResource.sshTerminal,
        issuedAt: DateTime.utc(2026),
        source: PersonalProfileSource.coreManaged,
      ),
      isNull,
    );
  });

  test('lease is exact to account route profile revision resource and age', () {
    final first = ProviderContainer();
    final second = ProviderContainer();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final account = first.read(personalRemoteAccountProvider);
    final otherAccount = second.read(personalRemoteAccountProvider);
    final route = Object();
    final issued = DateTime.utc(2026, 9, 20, 12);

    PersonalSessionLease lease() => PersonalSessionLease.capture(
      account: account,
      routeIdentity: route,
      profile: profile(RemoteProtocol.ssh),
      profileRevision: 7,
      resource: PersonalSessionResource.sshTerminal,
      issuedAt: issued,
    )!;

    bool current(
      PersonalSessionLease value, {
      PersonalRemoteAccount? candidateAccount,
      Object? candidateRoute,
      String? candidateProfile,
      int revision = 7,
      PersonalSessionResource resource = PersonalSessionResource.sshTerminal,
      DateTime? now,
      bool gate = true,
      bool foreground = true,
      bool interaction = true,
      bool routeCurrent = true,
    }) => value.isCurrent(
      account: candidateAccount ?? account,
      routeIdentity: candidateRoute ?? route,
      profileId: candidateProfile ?? '0123456789abcdef0123456789abcdef',
      profileRevision: revision,
      resource: resource,
      now: now ?? issued,
      gateCurrent: gate,
      foreground: foreground,
      interactionActive: interaction,
      routeCurrent: routeCurrent,
    );

    expect(current(lease()), isTrue);
    expect(current(lease(), candidateAccount: otherAccount), isFalse);
    expect(current(lease(), candidateRoute: Object()), isFalse);
    expect(
      current(lease(), candidateProfile: 'ffffffffffffffffffffffffffffffff'),
      isFalse,
    );
    expect(current(lease(), revision: 8), isFalse);
    expect(
      current(lease(), resource: PersonalSessionResource.sftpFiles),
      isFalse,
    );
    expect(current(lease(), gate: false), isFalse);
    expect(current(lease(), foreground: false), isFalse);
    expect(current(lease(), interaction: false), isFalse);
    expect(current(lease(), routeCurrent: false), isFalse);
    expect(
      current(lease(), now: issued.add(PersonalSessionLease.maximumLifetime)),
      isTrue,
    );
    expect(
      current(
        lease(),
        now: issued
            .add(PersonalSessionLease.maximumLifetime)
            .add(const Duration(microseconds: 1)),
      ),
      isFalse,
    );
  });

  test('retirement is one way and diagnostics redact personal data', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final account = container.read(personalRemoteAccountProvider);
    final route = Object();
    final issued = DateTime.utc(2026);
    final lease = PersonalSessionLease.capture(
      account: account,
      routeIdentity: route,
      profile: profile(RemoteProtocol.ssh),
      profileRevision: 1,
      resource: PersonalSessionResource.sftpFiles,
      issuedAt: issued,
    )!;
    final diagnostic = '$account $lease';
    expect(diagnostic, contains('redacted'));
    for (final secret in [
      'secret.internal.example',
      'private-user',
      '0123456789abcdef0123456789abcdef',
    ]) {
      expect(diagnostic, isNot(contains(secret)));
    }
    lease.retire();
    expect(
      lease.isCurrent(
        account: account,
        routeIdentity: route,
        profileId: '0123456789abcdef0123456789abcdef',
        profileRevision: 1,
        resource: PersonalSessionResource.sftpFiles,
        now: issued,
        gateCurrent: true,
        foreground: true,
        interactionActive: true,
        routeCurrent: true,
      ),
      isFalse,
    );
  });
}
