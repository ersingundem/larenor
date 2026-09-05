import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/action_status_indicator.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../ha_tools/presentation/ha_actions_screen.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/providers/action_providers.dart';
import '../../../health/providers/ha_actions.dart';
import '../dashboard_edit_guard.dart';

double? finiteTileNumber(dynamic value) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  return number != null && number.isFinite ? number : null;
}

bool tileHasFeature(HaEntity entity, int flag) =>
    (finiteTileNumber(entity.attributes['supported_features'])?.toInt() ?? 0) &
        flag !=
    0;

/// Tile controls share the same target lock and result semantics as More Info.
/// Draft gestures and late UI completions belong to one entity/account epoch.
mixin TileActionSupport<T extends ConsumerStatefulWidget>
    on DashboardEditState<T> {
  String? get actionEntityId;
  bool tileActionBusy = false;
  String? tileActionError;
  int tileActionGeneration = 0;
  bool _tileVisible = true;

  @override
  void invalidateDashboardInteraction() {
    resetTileAction();
    super.invalidateDashboardInteraction();
  }

  VoidCallback tileAction(VoidCallback action) {
    final generation = interactionGeneration;
    final tileGeneration = tileActionGeneration;
    return () {
      if (interactionCurrent(generation) &&
          tileGeneration == tileActionGeneration) {
        action();
      }
    };
  }

  ValueChanged<V> tileValueAction<V>(ValueChanged<V> action) {
    final generation = interactionGeneration;
    final tileGeneration = tileActionGeneration;
    return (value) {
      if (interactionCurrent(generation) &&
          tileGeneration == tileActionGeneration) {
        action(value);
      }
    };
  }

  void resetTileDrafts() {}

  void resetTileAction() {
    tileActionGeneration++;
    tileActionBusy = false;
    tileActionError = null;
    resetTileDrafts();
  }

  void watchTileActions() {
    ref.watch(connectionConfigProvider);
    watchDashboardAccount();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (_tileVisible && !visible) resetTileAction();
    _tileVisible = visible;
    ref.watch(haActionsProvider);
  }

  bool tileServiceAvailable(HaEntity entity, String service, {int? feature}) {
    if (!interactionCurrent(interactionGeneration) ||
        entity.entityId != actionEntityId ||
        entity.state == 'unavailable') {
      return false;
    }
    if (feature != null && !tileHasFeature(entity, feature)) return false;
    final catalog = ref.read(haActionsProvider);
    if (catalog.isLoading || catalog.hasError) return false;
    return catalog.value?.any(
          (action) =>
              action.domain == entity.domain && action.service == service,
        ) ??
        false;
  }

  Future<void> executeTileAction(
    String domain,
    String service, {
    int? feature,
    Map<String, dynamic> serviceData = const {},
  }) async {
    if (!interactionCurrent(interactionGeneration) || tileActionBusy) return;
    final states = ref.read(entitiesProvider);
    final account = ref.read(connectionConfigProvider);
    if (states.isLoading ||
        states.hasError ||
        account.isLoading ||
        account.hasError) {
      return;
    }
    final entity = states.value?[actionEntityId];
    if (entity == null ||
        entity.domain != domain ||
        !tileServiceAvailable(entity, service, feature: feature)) {
      return;
    }
    final generation = tileActionGeneration;
    final interaction = interactionGeneration;
    setState(() {
      tileActionBusy = true;
      tileActionError = null;
    });
    try {
      await ref
          .read(haActionExecutorProvider)
          .execute(
            domain: domain,
            service: service,
            entityId: entity.entityId,
            serviceData: serviceData,
          );
    } catch (error) {
      if (interactionCurrent(interaction) &&
          generation == tileActionGeneration) {
        setState(
          () => tileActionError = actionErrorLabel(
            AppLocalizations.of(context),
            error,
          ),
        );
      }
    } finally {
      if (interactionCurrent(interaction) &&
          generation == tileActionGeneration) {
        setState(() => tileActionBusy = false);
      }
    }
  }
}

class TileActionFeedback extends ConsumerWidget {
  const TileActionFeedback({
    super.key,
    required this.entityId,
    this.error,
    this.busy = false,
  });
  final String? entityId;
  final String? error;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receipt = ref.watch(
      actionReceiptsProvider.select(
        (state) => state.value
            ?.where(
              (item) =>
                  item.key.integration == IntegrationId.ha &&
                  item.key.target == entityId,
            )
            .firstOrNull,
      ),
    );
    final l10n = AppLocalizations.of(context);
    final label =
        error ??
        (busy
            ? l10n.actionSending
            : receipt == null
            ? null
            : actionStatusLabel(l10n, receipt));
    if (label == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption1.copyWith(
            color: error == null
                ? CupertinoColors.secondaryLabel.resolveFrom(context)
                : CupertinoColors.systemRed.resolveFrom(context),
          ),
        ),
      ),
    );
  }
}

/// Imported dashboard tiles can be as short as a standard accessory card.
/// Keep their controls reachable without overflowing the parent grid cell.
class TileContentViewport extends StatelessWidget {
  const TileContentViewport({super.key, required this.builder});
  final Widget Function(BuildContext context, double availableHeight) builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      primary: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: builder(context, constraints.maxHeight),
      ),
    ),
  );
}
