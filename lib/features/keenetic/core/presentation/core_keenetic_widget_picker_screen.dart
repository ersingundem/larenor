import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
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

  Future<void> _select(HomeResourceRecord target) async {
    if (_expired || _busy || _returned) return;
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
      if (!interactionCurrent(generation) || _expired || _returned) return;
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
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.coreKeeneticDashboardPickerTitle),
      ),
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(20),
              sliver: SliverToBoxAdapter(
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
            ),
            if (reading?.hasValue == true)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList.builder(
                  itemCount: reading!.value!.length,
                  itemBuilder: (context, index) {
                    final target = reading.value![index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: CupertinoButton(
                        key: ValueKey('core-keenetic-pick-${target.id}'),
                        minimumSize: const Size(48, 48),
                        color: CupertinoColors.secondarySystemGroupedBackground
                            .resolveFrom(context),
                        onPressed: _busy
                            ? null
                            : dashboardAction(() => unawaited(_select(target))),
                        child: Row(
                          children: [
                            const Icon(CupertinoIcons.wifi),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                target.label,
                                style: AppText.body.copyWith(
                                  color: CupertinoColors.label.resolveFrom(
                                    context,
                                  ),
                                ),
                              ),
                            ),
                            const Icon(CupertinoIcons.chevron_forward),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
