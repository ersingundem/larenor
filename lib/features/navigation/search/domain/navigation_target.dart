import '../../../media/hub/domain/media_identity.dart';
import '../../../media/hub/domain/media_title.dart';
import '../../../settings/data/app_service.dart';

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
        jellyfinItemId: title.jellyfinItemId,
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
