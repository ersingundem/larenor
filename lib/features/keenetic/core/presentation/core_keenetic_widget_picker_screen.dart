import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../dashboard/presentation/dashboard_edit_guard.dart';
import '../../../dashboard/domain/tile_config.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/domain/server_models.dart';
import '../data/core_keenetic_dashboard_providers.dart';

class CoreKeeneticWidgetPickerScreen extends ConsumerStatefulWidget {
  const CoreKeeneticWidgetPickerScreen({
    super.key,
    this.tileType = TileType.coreKeenetic,
  });
  final TileType tileType;
  @override
  ConsumerState<CoreKeeneticWidgetPickerScreen> createState() =>
      _CoreKeeneticWidgetPickerScreenState();
}

class _CoreKeeneticWidgetPickerScreenState
    extends DashboardEditState<CoreKeeneticWidgetPickerScreen> {
  bool _expired = false, _busy = false, _returned = false;
  String? _failure;
  @override
  void invalidateDashboardInteraction() => _expired = true;

  bool _targetCurrent(HomeResourceRecord target) {
    final resources = ref.read(coreKeeneticDashboardResourcesProvider);
    if (resources.isLoading || resources.hasError) return false;
    return resources.value?.any(
          (current) =>
              current.context == target.context &&
              current.id == target.id &&
              current.kind == target.kind &&
              current.revision == target.revision &&
              current.aclRevision == target.aclRevision,
        ) ==
        true;
  }

  Future<void> _select(HomeResourceRecord target) async {
    if (_expired || _busy || _returned || !_targetCurrent(target)) return;
    final generation = interactionGeneration;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final tile = widget.tileType == TileType.coreKeenetic
          ? await ref.read(coreKeeneticDashboardDraftProvider(target).future)
          : await ref.read(
              coreKeeneticDashboardVariantDraftProvider((
                target: target,
                type: widget.tileType,
              )).future,
            );
      if (!interactionCurrent(generation) ||
          _expired ||
          _returned ||
          !_targetCurrent(target)) {
        return;
      }
      _returned = true;
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, tile);
      }
    } catch (error) {
      if (interactionCurrent(generation)) {
        setState(
          () => _failure = error is LarenorServerException
              ? error.code
              : 'connection_failed',
        );
      }
    } finally {
      if (mounted && !_returned) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final failureText = switch (_failure) {
      'not_found' => l.coreKeeneticNoBinding,
      'forbidden' || 'unauthorized' => l.coreKeeneticPermission,
      'keenetic_upstream_denied' => l.coreKeeneticDenied,
      'keenetic_snapshot_unsupported' ||
      'invalid_response' => l.coreKeeneticUnsupported,
      'resource_changed' || 'conflict' => l.coreKeeneticChanged,
      null => null,
      _ => l.coreKeeneticOffline,
    };
    final reading = _expired
        ? null
        : ref.watch(coreKeeneticDashboardResourcesProvider);
    return ServiceRootScaffold(
      title: l.coreKeeneticDashboardPickerTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('core-keenetic-picker-header'),
              header: true,
              child: Text(l.coreKeeneticDashboardPickerTitle),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.coreKeeneticDashboardPickerHint,
                      style: AppText.body,
                    ),
                    if (_expired) Text(l.dashboardWidgetPickerExpired),
                    if (reading?.isLoading == true || _busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (reading?.hasError == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(l.coreKeeneticOffline),
                      ),
                    if (failureText != null)
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(failureText),
                        ),
                      ),
                    if (reading?.hasValue == true && reading!.value!.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(l.homeResourcesEmpty),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (reading?.hasValue == true)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.builder(
              itemCount: reading!.value!.length,
              itemBuilder: (context, index) {
                final target = reading.value![index];
                return SettingsActionTile(
                  buttonKey: ValueKey('core-keenetic-pick-${target.id}'),
                  leading: const Icon(CupertinoIcons.wifi),
                  title: Text(target.label, style: AppText.body),
                  onTap: _busy
                      ? null
                      : dashboardAction(() => unawaited(_select(target))),
                );
              },
            ),
          ),
      ],
    );
  }
}
