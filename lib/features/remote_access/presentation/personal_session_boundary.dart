import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/remote_profiles.dart';

/// The device-personal account scope is intentionally unrelated to a Core,
/// Home Assistant, Proxmox or media account. Replacing the provider container
/// creates a new identity and retires every lease captured by the old account.
final personalRemoteAccountProvider = Provider<PersonalRemoteAccount>(
  (_) => PersonalRemoteAccount._(),
);

class PersonalRemoteAccount {
  PersonalRemoteAccount._();

  @override
  String toString() => 'PersonalRemoteAccount(redacted)';
}

enum PersonalProfileSource { deviceLocal, coreManaged }

enum PersonalSessionResource { sshTerminal, sftpFiles, sshTunnel, desktop }

/// A closed, least-privilege policy. A profile can only mint a lease for the
/// one resource selected by the user; unknown/Core-managed resources cannot be
/// inferred from the local record.
abstract final class PersonalSessionPolicy {
  static Set<PersonalSessionResource> allowedFor(RemoteProtocol protocol) =>
      switch (protocol) {
        RemoteProtocol.ssh => const {
          PersonalSessionResource.sshTerminal,
          PersonalSessionResource.sftpFiles,
          PersonalSessionResource.sshTunnel,
        },
        RemoteProtocol.rdp ||
        RemoteProtocol.vnc => const {PersonalSessionResource.desktop},
      };

  static bool allows(
    RemoteProtocol protocol,
    PersonalSessionResource resource,
  ) => allowedFor(protocol).contains(resource);
}

/// A memory-only capability for one profile resource. It deliberately carries
/// no host, username, credential, command or trust material.
class PersonalSessionLease {
  PersonalSessionLease._({
    required this._account,
    required this._routeIdentity,
    required this._profileId,
    required this._profileRevision,
    required this.source,
    required this.resource,
    required DateTime issuedAt,
  }) : _expiresAt = issuedAt.add(maximumLifetime);

  static const maximumLifetime = Duration(minutes: 15);

  final PersonalRemoteAccount _account;
  final Object _routeIdentity;
  final String _profileId;
  final int _profileRevision;
  final DateTime _expiresAt;
  final PersonalProfileSource source;
  final PersonalSessionResource resource;
  bool _retired = false;

  static PersonalSessionLease? capture({
    required PersonalRemoteAccount account,
    required Object routeIdentity,
    required RemoteProfile profile,
    required int profileRevision,
    required PersonalSessionResource resource,
    required DateTime issuedAt,
    PersonalProfileSource source = PersonalProfileSource.deviceLocal,
  }) {
    if (profileRevision < 0 ||
        source != PersonalProfileSource.deviceLocal ||
        !PersonalSessionPolicy.allows(profile.protocol, resource)) {
      return null;
    }
    return PersonalSessionLease._(
      account: account,
      routeIdentity: routeIdentity,
      profileId: profile.id,
      profileRevision: profileRevision,
      source: source,
      resource: resource,
      issuedAt: issuedAt,
    );
  }

  bool isCurrent({
    required PersonalRemoteAccount account,
    required Object routeIdentity,
    required String profileId,
    required int profileRevision,
    required PersonalSessionResource resource,
    required DateTime now,
    required bool gateCurrent,
    required bool foreground,
    required bool interactionActive,
    required bool routeCurrent,
  }) {
    if (_retired ||
        !identical(_account, account) ||
        !identical(_routeIdentity, routeIdentity) ||
        _profileId != profileId ||
        _profileRevision != profileRevision ||
        this.resource != resource ||
        now.isAfter(_expiresAt) ||
        !gateCurrent ||
        !foreground ||
        !interactionActive ||
        !routeCurrent) {
      _retired = true;
      return false;
    }
    return true;
  }

  void retire() => _retired = true;

  @override
  String toString() =>
      'PersonalSessionLease(source: ${source.name}, resource: ${resource.name}, redacted)';
}
