import 'dart:convert';

import 'server_models.dart';

const maxServerHomeProfiles = 16;

final class ServerHomeProfile {
  const ServerHomeProfile({
    required this.profileId,
    required this.label,
    required this.session,
  });

  factory ServerHomeProfile.fromStorage(Object? raw) {
    final json = serverObject(raw);
    if (json.length != 3 ||
        !json.keys.every(const {'profileId', 'label', 'session'}.contains)) {
      throw const LarenorServerException('invalid_session');
    }
    final profileId = json['profileId'];
    final label = json['label'];
    if (profileId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(profileId) ||
        label is! String ||
        label != label.trim() ||
        label.isEmpty ||
        label.length > 80 ||
        label.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const LarenorServerException('invalid_session');
    }
    final session = json['session'];
    if (session is! Map<String, dynamic>) {
      throw const LarenorServerException('invalid_session');
    }
    return ServerHomeProfile(
      profileId: profileId,
      label: label,
      session: ServerSession.decodeStorage(jsonEncode(session)),
    );
  }

  final String profileId;
  final String label;
  final ServerSession session;

  ServerHomeProfile withSession(ServerSession value) =>
      ServerHomeProfile(profileId: profileId, label: label, session: value);

  ServerHomeProfile withLabel(String value) =>
      ServerHomeProfile(profileId: profileId, label: value, session: session);

  Map<String, Object?> toStorage() => {
    'profileId': profileId,
    'label': label,
    'session': jsonDecode(session.encodeStorage()),
  };

  @override
  String toString() => 'ServerHomeProfile';
}

/// Client-local profile registry. Core/home/user remains the authority tuple;
/// profileId and label only select one securely stored session on this device.
final class ServerHomeRegistry {
  const ServerHomeRegistry({
    required this.activeProfileId,
    required this.profiles,
  });

  const ServerHomeRegistry.empty()
    : activeProfileId = null,
      profiles = const [];

  factory ServerHomeRegistry.decode(String encoded) {
    try {
      if (encoded.length > 300000) {
        throw const LarenorServerException('invalid_session');
      }
      final json = serverObject(jsonDecode(encoded));
      if (json.length != 3 ||
          json['version'] != 4 ||
          !json.keys.every(
            const {'version', 'activeProfileId', 'profiles'}.contains,
          )) {
        throw const LarenorServerException('invalid_session');
      }
      final rawProfiles = json['profiles'];
      final active = json['activeProfileId'];
      if (rawProfiles is! List ||
          rawProfiles.length > maxServerHomeProfiles ||
          active != null &&
              (active is! String ||
                  !RegExp(r'^[0-9a-f]{32}$').hasMatch(active))) {
        throw const LarenorServerException('invalid_session');
      }
      final profiles = List<ServerHomeProfile>.unmodifiable(
        rawProfiles.map(ServerHomeProfile.fromStorage),
      );
      final ids = profiles.map((item) => item.profileId).toSet();
      final authorities = <String>{};
      for (final profile in profiles) {
        final context = profile.session.context;
        if (context == null) continue;
        final authority =
            '${context.coreId}:${context.homeId}:${profile.session.user.id}';
        if (!authorities.add(authority)) {
          throw const LarenorServerException('invalid_session');
        }
      }
      if (ids.length != profiles.length ||
          active != null && !ids.contains(active)) {
        throw const LarenorServerException('invalid_session');
      }
      return ServerHomeRegistry(
        activeProfileId: active as String?,
        profiles: profiles,
      );
    } catch (_) {
      throw const LarenorServerException('invalid_session');
    }
  }

  final String? activeProfileId;
  final List<ServerHomeProfile> profiles;

  ServerHomeProfile? get activeProfile {
    final active = activeProfileId;
    if (active == null) return null;
    return profiles.singleWhere((item) => item.profileId == active);
  }

  String encode() => jsonEncode({
    'version': 4,
    'activeProfileId': activeProfileId,
    'profiles': profiles.map((item) => item.toStorage()).toList(),
  });

  @override
  String toString() => 'ServerHomeRegistry';
}
