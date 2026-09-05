import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/data/media_api_exception.dart';
import '../../media/hub/domain/media_identity.dart';
import '../../media/hub/domain/media_title.dart';
import '../../media/hub/providers/media_catalog_providers.dart';
import '../../media/hub/providers/media_details_providers.dart';
import '../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../media/jellyseerr/providers/jellyseerr_providers.dart';

MediaIdentity? mediaIdentityFromLocation(Uri location) {
  if (location.queryParametersAll.values.any((values) => values.length != 1)) {
    return null;
  }
  final query = location.queryParameters;
  final kind = MediaKind.values
      .where((v) => v.name == query['kind'])
      .firstOrNull;
  if (kind == null) return null;
  int? positive(String? value) {
    if (value == null) return null;
    final id = int.tryParse(value);
    return id != null && id > 0 ? id : null;
  }

  final tmdb = positive(query['tmdb']);
  final tvdb = positive(query['tvdb']);
  final imdb = query['imdb'];
  if ((query.containsKey('tmdb') && tmdb == null) ||
      (query.containsKey('tvdb') && tvdb == null) ||
      (imdb != null && !RegExp(r'^tt[0-9]+$').hasMatch(imdb))) {
    return null;
  }
  final jellyfin = query['jellyfin'];
  for (final id in [jellyfin, query['series']]) {
    if (id != null && !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) {
      return null;
    }
  }
  final identity = MediaIdentity(
    kind: kind,
    tmdbId: tmdb,
    tvdbId: tvdb,
    imdbId: imdb,
  );
  return identity.isEmpty && jellyfin == null ? null : identity;
}

final mediaDestinationProvider = FutureProvider.autoDispose
    .family<MediaTitle?, Uri>((ref, location) async {
      final identity = mediaIdentityFromLocation(location);
      if (identity == null) return null;
      final client = ref.watch(jellyfinClientProvider);
      final seerr = ref.watch(jellyseerrClientProvider);
      final itemId = location.queryParameters['jellyfin'];
      Object? failure;
      if (itemId != null && client != null) {
        try {
          final item = await client.getItem(itemId);
          if (!ref.mounted) return null;
          final title = mediaTitleFromJellyfin(item, imageUrl: client.imageUrl);
          if (item.id == itemId &&
              title != null &&
              title.identity.kind == identity.kind &&
              (identity.isEmpty || title.identity.matches(identity))) {
            return title;
          }
        } catch (error) {
          if (error is! MediaApiException || error.statusCode != 404) {
            failure = error;
          }
        }
      }
      if (!ref.mounted) return null;
      if (seerr != null && identity.tmdbId != null) {
        try {
          final details = await ref.watch(
            mediaCatalogueDetailsProvider(identity).future,
          );
          if (!ref.mounted) return null;
          if (details != null) {
            return mediaTitleFromJellyseerr(
              details.result,
              posterUrl: seerr.posterUrl,
              backdropUrl: seerr.backdropUrl,
            );
          }
        } catch (error) {
          if (error is! MediaApiException || error.statusCode != 404) {
            failure = error;
          }
        }
      }
      if (!ref.mounted) return null;
      // External IDs can resolve against the account's library without
      // depending on a title being present in the current trending feed.
      final index = await ref.watch(mediaLibraryIndexProvider.future);
      if (!ref.mounted) return null;
      final indexedTitle = index.titleFor(identity);
      if (indexedTitle != null) return indexedTitle;
      final indexedItem = index.jellyfinItem(
        index.lookup(identity)?.jellyfinItemId,
      );
      if (indexedItem != null && client != null) {
        final title = mediaTitleFromJellyfin(
          indexedItem,
          imageUrl: client.imageUrl,
        );
        if (title != null) return index.enrich(title);
      }
      final cachedRows = ref.exists(mediaHubRowsProvider)
          ? ref.watch(mediaHubRowsProvider)
          : null;
      for (final row
          in cachedRows != null && !cachedRows.isReloading
              ? cachedRows.value ?? const <MediaRowData>[]
              : const <MediaRowData>[]) {
        for (final title in row.titles) {
          if (title.identity.matches(identity)) return index.enrich(title);
        }
      }
      if (failure != null) throw failure;
      return null;
    }, retry: (_, _) => null);
