import '../../../media/hub/domain/media_identity.dart';
import '../../../media/hub/domain/media_title.dart';
import '../../../settings/data/app_service.dart';
import '../../../home_resources/domain/home_resource_models.dart';

/// A navigation request, never a service call. URLs contain identifiers only;
/// credentials and mutable presentation titles never form part of a target.
sealed class NavigationTarget {
  const NavigationTarget();
  Uri get uri;
  String get location => uri.toString();

  @override
  bool operator ==(Object other) =>
      other is NavigationTarget && other.location == location;

  @override
  int get hashCode => location.hashCode;
}

enum HomePageTarget { today, intercom, energy }

enum MediaPageTarget { music, sources, audio }

final class MediaPageNavigationTarget extends NavigationTarget {
  const MediaPageNavigationTarget(this.page);
  final MediaPageTarget page;
  @override
  Uri get uri => Uri(path: '/media/${page.name}');
}

final class HomePageNavigationTarget extends NavigationTarget {
  const HomePageNavigationTarget(this.page);
  final HomePageTarget page;
  @override
  Uri get uri => Uri(path: '/${page.name}');
}

final class RoomNavigationTarget extends NavigationTarget {
  const RoomNavigationTarget(this.roomId);
  final String roomId;
  @override
  Uri get uri => Uri(pathSegments: ['', 'rooms', roomId]);
}

final class EntityNavigationTarget extends NavigationTarget {
  const EntityNavigationTarget(this.entityId);
  final String entityId;
  @override
  Uri get uri => Uri(pathSegments: ['', 'entities', entityId]);
}

/// An account-scoped Core metadata destination. Mutable labels and secrets are
/// excluded; every revision is carried so the destination can require an exact
/// match against the current authorized catalog before it renders an action.
final class CoreResourceNavigationTarget extends NavigationTarget {
  const CoreResourceNavigationTarget({
    required this.coreId,
    required this.homeId,
    required this.resourceId,
    required this.kind,
    required this.resourceRevision,
    required this.aclRevision,
    required this.userRevision,
  });

  factory CoreResourceNavigationTarget.fromRecord(
    HomeResourceRecord record, {
    required int userRevision,
  }) => CoreResourceNavigationTarget(
    coreId: record.context.coreId,
    homeId: record.context.homeId,
    resourceId: record.id,
    kind: record.kind,
    resourceRevision: record.revision,
    aclRevision: record.aclRevision,
    userRevision: userRevision,
  );

  static CoreResourceNavigationTarget? tryParse(Uri uri) {
    if (uri.pathSegments.length != 3 ||
        uri.pathSegments.first != 'core-resources' ||
        uri.queryParameters.keys.toSet().difference({
          'core',
          'home',
          'resourceRevision',
          'aclRevision',
          'userRevision',
        }).isNotEmpty) {
      return null;
    }
    final kind = switch (uri.pathSegments[1]) {
      'room' => HomeResourceKind.room,
      'resource' => HomeResourceKind.resource,
      _ => null,
    };
    final core = uri.queryParameters['core'];
    final home = uri.queryParameters['home'];
    final id = uri.pathSegments[2];
    int? revision(String key) {
      final value = int.tryParse(uri.queryParameters[key] ?? '');
      return value != null && value >= 1 && value <= 0x7fffffffffffffff
          ? value
          : null;
    }

    final resourceRevision = revision('resourceRevision');
    final aclRevision = revision('aclRevision');
    final userRevision = revision('userRevision');
    final identity = RegExp(r'^[0-9a-f]{32}$');
    if (kind == null ||
        core == null ||
        home == null ||
        !identity.hasMatch(core) ||
        !identity.hasMatch(home) ||
        !identity.hasMatch(id) ||
        resourceRevision == null ||
        aclRevision == null ||
        userRevision == null) {
      return null;
    }
    return CoreResourceNavigationTarget(
      coreId: core,
      homeId: home,
      resourceId: id,
      kind: kind,
      resourceRevision: resourceRevision,
      aclRevision: aclRevision,
      userRevision: userRevision,
    );
  }

  final String coreId, homeId, resourceId;
  final HomeResourceKind kind;
  final int resourceRevision, aclRevision, userRevision;

  @override
  Uri get uri => Uri(
    pathSegments: ['', 'core-resources', kind.name, resourceId],
    queryParameters: {
      'core': coreId,
      'home': homeId,
      'resourceRevision': '$resourceRevision',
      'aclRevision': '$aclRevision',
      'userRevision': '$userRevision',
    },
  );
}

final class MediaNavigationTarget extends NavigationTarget {
  const MediaNavigationTarget({
    required this.identity,
    this.jellyfinItemId,
    this.jellyfinSeriesId,
    this.snapshot,
  });

  factory MediaNavigationTarget.fromTitle(MediaTitle title) =>
      MediaNavigationTarget(
        identity: title.identity,
        jellyfinItemId: title.jellyfinItemId ?? title.jellyfinLookupId,
        jellyfinSeriesId: title.jellyfinSeriesId,
        snapshot: title,
      );

  final MediaIdentity identity;
  final String? jellyfinItemId;
  final String? jellyfinSeriesId;

  /// An already-cached title for immediate presentation. It is deliberately
  /// excluded from URL/equality so title updates never invalidate deep links.
  final MediaTitle? snapshot;

  @override
  Uri get uri => Uri(
    path: '/media/title',
    queryParameters: {
      'kind': identity.kind.name,
      if (identity.tmdbId != null) 'tmdb': '${identity.tmdbId}',
      if (identity.tvdbId != null) 'tvdb': '${identity.tvdbId}',
      'imdb': ?identity.imdbId,
      'jellyfin': ?jellyfinItemId,
      'series': ?jellyfinSeriesId,
    },
  );
}

final class SystemNavigationTarget extends NavigationTarget {
  const SystemNavigationTarget(this.service);
  final AppService service;
  @override
  Uri get uri => Uri(pathSegments: ['', 'system', service.name]);
}
