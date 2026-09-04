import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../dashboard/presentation/widgets/more_info_sheet.dart';
import '../../dashboard/presentation/home_dashboard_screen.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../media/hub/domain/media_identity.dart';
import '../../media/hub/domain/media_title.dart';
import '../../media/hub/presentation/media_title_detail_screen.dart';
import '../../media/hub/providers/media_catalog_providers.dart';
import '../../media/jellyfin/providers/jellyfin_providers.dart';

class RoomDestinationScreen extends ConsumerWidget {
  const RoomDestinationScreen({super.key, required this.roomId});
  final String roomId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(dashboardLayoutProvider)
      .when(
        data: (layout) => layout.rooms.any((room) => room.id == roomId)
            ? HomeDashboardScreen(embedded: true, initialRoomId: roomId)
            : const MissingDestinationScreen(),
        loading: () => const AppPageScaffold(
          child: Center(child: CupertinoActivityIndicator()),
        ),
        error: (_, _) => const MissingDestinationScreen(),
      );
}

class EntityDestinationScreen extends ConsumerWidget {
  const EntityDestinationScreen({super.key, required this.entityId});
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(
      entitiesProvider.select(
        (states) => states.value?[entityId]?.friendlyName,
      ),
    );
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: context.canPop()
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => context.go('/'),
                child: const Icon(CupertinoIcons.house),
              ),
        middle: Text(
          name ?? AppLocalizations.of(context).navigationSearchEntity,
        ),
      ),
      child: SafeArea(child: EntityMoreInfo(entityId: entityId, asPage: true)),
    );
  }
}

MediaIdentity? mediaIdentityFromLocation(Uri location) {
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
  if (jellyfin != null &&
      !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(jellyfin)) {
    return null;
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
      final index = await ref.watch(mediaLibraryIndexProvider.future);
      final itemId =
          location.queryParameters['jellyfin'] ??
          index.lookup(identity)?.jellyfinItemId;
      if (!ref.mounted) return null;
      final client = ref.watch(jellyfinClientProvider);
      if (itemId != null && client != null) {
        final item = await client.getItem(itemId);
        final title = mediaTitleFromJellyfin(item, imageUrl: client.imageUrl);
        if (title != null) return index.enrich(title);
      }
      // Deep links without a presentation snapshot resolve against refreshed
      // catalog data. No action/request is sent by resolving a destination.
      final rows = await ref.watch(mediaHubRowsProvider.future);
      for (final row in rows) {
        for (final title in row.titles) {
          if (title.identity.matches(identity)) return index.enrich(title);
        }
      }
      return null;
    });

class MediaDestinationScreen extends ConsumerWidget {
  const MediaDestinationScreen({
    super.key,
    required this.location,
    this.snapshot,
  });
  final Uri location;
  final MediaTitle? snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = mediaIdentityFromLocation(location);
    final initial = snapshot;
    if (identity != null &&
        initial != null &&
        (initial.identity.matches(identity) ||
            initial.jellyfinItemId != null &&
                initial.jellyfinItemId ==
                    location.queryParameters['jellyfin'])) {
      return MediaTitleDetailScreen(title: initial);
    }
    final result = ref.watch(mediaDestinationProvider(location));
    return result.when(
      data: (title) => title == null
          ? const MissingDestinationScreen()
          : MediaTitleDetailScreen(title: title),
      loading: () => const AppPageScaffold(
        navigationBar: CupertinoNavigationBar(),
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (_, _) => AppPageScaffold(
        navigationBar: const CupertinoNavigationBar(),
        child: Center(
          child: CupertinoButton(
            onPressed: () => ref.invalidate(mediaDestinationProvider(location)),
            child: Text(AppLocalizations.of(context).commonRetry),
          ),
        ),
      ),
    );
  }
}

class MissingDestinationScreen extends StatelessWidget {
  const MissingDestinationScreen({super.key});
  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(
      leading: context.canPop()
          ? null
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => context.go('/'),
              child: const Icon(CupertinoIcons.house),
            ),
    ),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(AppLocalizations.of(context).navigationDestinationMissing),
      ),
    ),
  );
}
