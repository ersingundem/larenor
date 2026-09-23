import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../data/media_archive_health_providers.dart';
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
          child: MediaArchiveHealthCard(controller: controller),
        ),
      ],
    );
  }
}
