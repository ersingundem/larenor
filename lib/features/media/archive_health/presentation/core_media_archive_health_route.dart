import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../server/media_archive_actions/presentation/server_media_archive_actions_route.dart';
import '../data/media_archive_health_providers.dart';
import '../domain/media_archive_health.dart';
import 'media_archive_health_card.dart';

/// Discoverable Core-owned archive evidence. Reads remain explicit and
/// read-only; the provider retires the snapshot with the account generation.
final class CoreMediaArchiveHealthRoute extends ConsumerWidget {
  const CoreMediaArchiveHealthRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(mediaArchiveHealthControllerProvider);
    return ServiceRootScaffold(
      title: AppLocalizations.of(context).mediaArchiveTitle,
      slivers: [
        SliverToBoxAdapter(
          child: MediaArchiveHealthCard(
            controller: controller,
            onOpenActions: (MediaArchiveHealthSnapshot snapshot) {
              context.push(
                Uri(
                  path: ServerMediaArchiveActionsRoute.path,
                  queryParameters: {
                    'installationId': snapshot.installationId,
                    'installationRevision': '${snapshot.installationRevision}',
                    'snapshotRevision': '${snapshot.snapshotRevision}',
                  },
                ).toString(),
              );
            },
          ),
        ),
      ],
    );
  }
}
