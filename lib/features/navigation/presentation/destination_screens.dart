import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../dashboard/presentation/widgets/more_info_sheet.dart';
import '../../dashboard/presentation/home_dashboard_screen.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../media/hub/domain/media_title.dart';
import '../../media/hub/presentation/media_title_detail_screen.dart';
import '../providers/media_destination_provider.dart';

export '../providers/media_destination_provider.dart';

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
    // A route's presentation snapshot does not prove which account supplied
    // its item IDs. Resolve afresh before making those IDs actionable.
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
