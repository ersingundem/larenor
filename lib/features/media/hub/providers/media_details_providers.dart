import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../jellyseerr/data/models/jellyseerr_details.dart';
import '../../jellyseerr/providers/jellyseerr_providers.dart';
import '../domain/media_identity.dart';

/// A read scoped to the current Seerr client/account. Opening a title, rather
/// than typing in local search, starts this direct catalogue request.
final mediaCatalogueDetailsProvider = FutureProvider.autoDispose
    .family<JellyseerrDetails?, MediaIdentity>((ref, identity) async {
      final client = ref.watch(jellyseerrClientProvider);
      if (client == null || identity.tmdbId == null) return null;
      final result = await client.getDetails(
        mediaType: identity.kind == MediaKind.tv ? 'tv' : 'movie',
        mediaId: identity.tmdbId!,
      );
      return ref.mounted ? result : null;
    }, retry: (_, _) => null);
