import 'package:larenor/features/media/hub/domain/media_identity.dart';

/// A catalog identity serialized exactly as the Core media-flow API accepts it.
///
/// Construction stays private so provider ids unsupported by Core cannot be
/// sent by accidentally reusing [MediaIdentity.key].
final class CoreMediaKey {
  const CoreMediaKey._(this.value);

  static const int _maxProviderId = 999999999999;

  final String value;

  static CoreMediaKey? fromIdentity(MediaIdentity identity) {
    final (prefix, providerId) = switch (identity.kind) {
      MediaKind.movie => ('movie:tmdb', identity.tmdbId),
      MediaKind.tv => ('series:tvdb', identity.tvdbId),
    };
    if (providerId == null || providerId < 1 || providerId > _maxProviderId) {
      return null;
    }
    return CoreMediaKey._('$prefix:$providerId');
  }

  @override
  bool operator ==(Object other) =>
      other is CoreMediaKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
