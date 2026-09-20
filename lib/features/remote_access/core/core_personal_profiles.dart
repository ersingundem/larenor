import '../../server/domain/server_models.dart';
import '../data/remote_profiles.dart';

const _maximumRevision = 9223372036854775807;

/// Public Core metadata only. Credentials and temporary session authority are
/// intentionally absent from this closed model.
final class CorePersonalProfile {
  const CorePersonalProfile._({
    required this.context,
    required this.profile,
    required this.revision,
  });

  factory CorePersonalProfile.fromJson(
    Object? input, {
    required ServerContext expectedContext,
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
    const refKeys = {'schemaVersion', 'coreId', 'homeId', 'kind', 'id'};
    if (ref.length != refKeys.length ||
        !ref.keys.toSet().containsAll(refKeys) ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != expectedContext.coreId ||
        ref['homeId'] != expectedContext.homeId ||
        ref['kind'] != 'remoteProfile') {
      throw const LarenorServerException('invalid_response');
    }
    final id = ref['id'];
    final revision = value['revision'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        revision is! int ||
        revision < 1 ||
        revision > _maximumRevision) {
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
        profile: profile,
        revision: revision,
      );
    } catch (_) {
      throw const LarenorServerException('invalid_response');
    }
  }

  final ServerContext context;
  final RemoteProfile profile;
  final int revision;
  String get id => profile.id;

  Map<String, Object> mutationJson({bool includeRevision = false}) => {
    'label': profile.name,
    'protocol': profile.protocol.name,
    'host': profile.host,
    'port': profile.port,
    'username': profile.username,
    if (includeRevision) 'expectedRevision': revision,
  };

  @override
  String toString() => 'CorePersonalProfile(redacted, revision: $revision)';
}

final class CorePersonalProfilesSnapshot {
  CorePersonalProfilesSnapshot._({
    required this.context,
    required this.collectionRevision,
    required List<CorePersonalProfile> profiles,
  }) : profiles = List.unmodifiable(profiles);

  factory CorePersonalProfilesSnapshot.fromJson(
    Object? input, {
    required ServerContext expectedContext,
  }) {
    final value = serverObject(input);
    const keys = {'scope', 'collectionRevision', 'profiles'};
    if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
      throw const LarenorServerException('invalid_response');
    }
    final scope = serverObject(value['scope']);
    if (scope.length != 3 ||
        scope['schemaVersion'] != 1 ||
        scope['coreId'] != expectedContext.coreId ||
        scope['homeId'] != expectedContext.homeId) {
      throw const LarenorServerException('invalid_response');
    }
    final revision = value['collectionRevision'];
    final list = value['profiles'];
    if (revision is! int ||
        revision < 0 ||
        revision > _maximumRevision ||
        list is! List ||
        list.length > 32) {
      throw const LarenorServerException('invalid_response');
    }
    final profiles = list
        .map(
          (item) => CorePersonalProfile.fromJson(
            item,
            expectedContext: expectedContext,
          ),
        )
        .toList(growable: false);
    if (profiles.map((profile) => profile.id).toSet().length !=
        profiles.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CorePersonalProfilesSnapshot._(
      context: expectedContext,
      collectionRevision: revision,
      profiles: profiles,
    );
  }

  final ServerContext context;
  final int collectionRevision;
  final List<CorePersonalProfile> profiles;

  @override
  String toString() =>
      'CorePersonalProfilesSnapshot(count: ${profiles.length}, redacted)';
}
