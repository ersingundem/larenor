import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../core_ha/presentation/core_ha_screen.dart';
import '../../core_proxmox/presentation/core_proxmox_screen.dart';
import '../../keenetic/core/presentation/core_keenetic_screen.dart';
import '../../navigation/search/domain/navigation_target.dart';
import '../../server/providers/server_providers.dart';
import '../data/home_resources_providers.dart';
import '../domain/home_resource_models.dart';

/// Resolves a search/card reference against the current account catalog at
/// action time. A retained stale row may be shown elsewhere, but it cannot
/// enter any device/service surface through this gate.
class CoreResourceDestinationScreen extends ConsumerWidget {
  const CoreResourceDestinationScreen({super.key, required this.target});

  final CoreResourceNavigationTarget target;

  HomeResourceRecord? _current(WidgetRef ref) {
    final catalog = ref.read(sharedHomeResourcesProvider);
    if (catalog == null ||
        !catalog.fresh ||
        catalog.stale ||
        catalog.userRevision != target.userRevision) {
      return null;
    }
    return catalog.entries.where((record) {
      return record.context.coreId == target.coreId &&
          record.context.homeId == target.homeId &&
          record.id == target.resourceId &&
          record.kind == target.kind &&
          record.revision == target.resourceRevision &&
          record.aclRevision == target.aclRevision;
    }).firstOrNull;
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Widget Function(HomeResourceRecord) page,
  ) async {
    final record = _current(ref);
    if (record == null || !context.mounted) return;
    await Navigator.of(context)
        .push<void>(CupertinoPageRoute(builder: (_) => page(record)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final catalog = ref.watch(sharedHomeResourcesProvider);
    final record = _current(ref);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.homeResourcesTitle),
      ),
      child: SafeArea(
        child: ListView(
          key: const ValueKey('core-resource-destination'),
          padding: const EdgeInsets.all(Gap.xl),
          children: [
            if (record == null) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  catalog?.busy == true
                      ? l10n.homeResourcesLoading
                      : l10n.homeCoreVerificationRequired,
                  key: const ValueKey('core-resource-destination-inert'),
                  style: AppText.body,
                ),
              ),
              const SizedBox(height: Gap.lg),
              CupertinoButton.filled(
                key: const ValueKey('core-resource-destination-refresh'),
                onPressed: catalog?.canRefresh == true
                    ? () => unawaited(catalog!.refresh())
                    : null,
                child: Text(l10n.commonRefresh),
              ),
            ] else ...[
              Semantics(
                header: true,
                child: Text(record.label, style: AppText.largeTitle),
              ),
              const SizedBox(height: Gap.sm),
              Text(
                record.kind == HomeResourceKind.room
                    ? l10n.homeResourcesRoom
                    : l10n.homeResourcesResource,
                style: AppText.body,
              ),
              if (record.kind == HomeResourceKind.resource) ...[
                const SizedBox(height: Gap.xl),
                CupertinoButton.filled(
                  key: const ValueKey('core-resource-open-ha'),
                  onPressed: () => _open(
                    context,
                    ref,
                    (current) => CoreHaScreen(target: current),
                  ),
                  child: Text(l10n.coreHaOpen),
                ),
                const SizedBox(height: Gap.md),
                CupertinoButton(
                  key: const ValueKey('core-resource-open-keenetic'),
                  onPressed: () => _open(
                    context,
                    ref,
                    (current) => CoreKeeneticScreen(
                      target: current,
                      admin:
                          ref
                              .read(serverAccountControllerProvider)
                              .session
                              ?.user
                              .canAdminister ==
                          true,
                    ),
                  ),
                  child: Text(l10n.coreKeeneticOpen),
                ),
                CupertinoButton(
                  key: const ValueKey('core-resource-open-proxmox'),
                  onPressed: () => _open(
                    context,
                    ref,
                    (current) => CoreProxmoxScreen(target: current),
                  ),
                  child: Text(l10n.coreProxmoxOpen),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
