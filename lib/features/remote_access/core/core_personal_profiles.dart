import '../../server/domain/server_models.dart';
import '../data/remote_profiles.dart';

const _maximumRevision = 9223372036854775807;
final _identity = RegExp(r'^[0-9a-f]{32}$');

String _id(Object? value) {
  if (value is! String || !_identity.hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _revision(Object? value, {bool allowZero = false}) {
  if (value is! int ||
      value < (allowZero ? 0 : 1) ||
      value > _maximumRevision) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

/// Server authority for one account and one authenticated token family.
final class CorePersonalProfileAuthority {
  const CorePersonalProfileAuthority._({
    required this.context,
    required this.accountId,
    required this.sessionFamilyId,
    required this.accountRevision,
    required this.collectionRevision,
  });

  factory CorePersonalProfileAuthority.fromJson(
    Object? input, {
    required ServerContext expectedContext,
    required String expectedAccountId,
    String? expectedSessionFamilyId,
    int? expectedAccountRevision,
  }) {
    final value = serverObject(input);
    const keys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'accountRevision',
      'collectionRevision',
    };
    if (value.length != keys.length ||
        !value.keys.toSet().containsAll(keys) ||
        value['schemaVersion'] != 1 ||
        value['coreId'] != expectedContext.coreId ||
        value['homeId'] != expectedContext.homeId) {
      throw const LarenorServerException('invalid_response');
    }
    final accountId = _id(value['accountId']);
    final sessionFamilyId = _id(value['sessionFamilyId']);
    final accountRevision = _revision(value['accountRevision']);
    if (accountId != expectedAccountId ||
        expectedSessionFamilyId != null &&
            sessionFamilyId != expectedSessionFamilyId ||
        expectedAccountRevision != null &&
            accountRevision != expectedAccountRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return CorePersonalProfileAuthority._(
      context: expectedContext,
      accountId: accountId,
      sessionFamilyId: sessionFamilyId,
      accountRevision: accountRevision,
      collectionRevision: _revision(
        value['collectionRevision'],
        allowZero: true,
      ),
    );
  }

  final ServerContext context;
  final String accountId, sessionFamilyId;
  final int accountRevision, collectionRevision;

  @override
  String toString() =>
      'CorePersonalProfileAuthority(revisions: $accountRevision/$collectionRevision, redacted)';
}

/// Public Core metadata only. Credentials and temporary session authority are
/// intentionally absent from this closed model.
final class CorePersonalProfile {
  const CorePersonalProfile._({
    required this.context,
    required this.accountId,
    required this.profile,
    required this.revision,
  });

  factory CorePersonalProfile.fromJson(
    Object? input, {
    required ServerContext expectedContext,
    required String expectedAccountId,
  }) {
    final value = serverObject(input);
    const keys = {
      'ref',
      'revision',
      'label',
      'protocol',
      'host',
      'port',
      'username',
    };
    if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
      throw const LarenorServerException('invalid_response');
    }
    final ref = serverObject(value['ref']);
    const refKeys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
      'accountId',
    };
    if (ref.length != refKeys.length ||
        !ref.keys.toSet().containsAll(refKeys) ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != expectedContext.coreId ||
        ref['homeId'] != expectedContext.homeId ||
        ref['kind'] != 'coreRemoteProfile') {
      throw const LarenorServerException('invalid_response');
    }
    final id = _id(ref['id']);
    final accountId = _id(ref['accountId']);
    if (accountId != expectedAccountId) {
      throw const LarenorServerException('invalid_response');
    }
    try {
      final profile = RemoteProfile.fromJson({
        'id': id,
        'name': value['label'],
        'protocol': value['protocol'],
        'host': value['host'],
        'port': value['port'],
        'username': value['username'],
      });
      return CorePersonalProfile._(
        context: expectedContext,
        accountId: accountId,
        profile: profile,
        revision: _revision(value['revision']),
      );
    } catch (_) {
      throw const LarenorServerException('invalid_response');
    }
  }

  final ServerContext context;
  final String accountId;
  final RemoteProfile profile;
  final int revision;
  String get id => profile.id;

  @override
  String toString() => 'CorePersonalProfile(redacted, revision: $revision)';
}

final class CorePersonalProfilesSnapshot {
  CorePersonalProfilesSnapshot._({
    required this.authority,
    required List<CorePersonalProfile> profiles,
  }) : profiles = List.unmodifiable(profiles);

  factory CorePersonalProfilesSnapshot.fromJson(
    Object? input, {
    required ServerContext expectedContext,
    required String expectedAccountId,
    String? expectedSessionFamilyId,
    int? expectedAccountRevision,
  }) {
    final value = serverObject(input);
    const keys = {'authority', 'profiles'};
    if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
      throw const LarenorServerException('invalid_response');
    }
    final authority = CorePersonalProfileAuthority.fromJson(
      value['authority'],
      expectedContext: expectedContext,
      expectedAccountId: expectedAccountId,
      expectedSessionFamilyId: expectedSessionFamilyId,
      expectedAccountRevision: expectedAccountRevision,
    );
    final list = value['profiles'];
    if (list is! List || list.length > 32) {
      throw const LarenorServerException('invalid_response');
    }
    final profiles = list
        .map(
          (item) => CorePersonalProfile.fromJson(
            item,
            expectedContext: expectedContext,
            expectedAccountId: expectedAccountId,
          ),
        )
        .toList(growable: false);
    if (profiles.map((profile) => profile.id).toSet().length !=
        profiles.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CorePersonalProfilesSnapshot._(
      authority: authority,
      profiles: profiles,
    );
  }

  final CorePersonalProfileAuthority authority;
  final List<CorePersonalProfile> profiles;
  ServerContext get context => authority.context;
  int get collectionRevision => authority.collectionRevision;

  @override
  String toString() =>
      'CorePersonalProfilesSnapshot(count: ${profiles.length}, redacted)';
}

final class CorePersonalProfileMutation {
  const CorePersonalProfileMutation({
    required this.authority,
    this.profile,
    this.deletedId,
    this.deletedRevision,
  });

  final CorePersonalProfileAuthority authority;
  final CorePersonalProfile? profile;
  final String? deletedId;
  final int? deletedRevision;
}
