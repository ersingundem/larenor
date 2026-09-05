import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../data/entity_history.dart';
import '../../domain/tile_config.dart';
import '../../providers/entity_history_providers.dart';

class HistoryTile extends ConsumerStatefulWidget {
  const HistoryTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends ConsumerState<HistoryTile> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (mounted) {
          setState(() => _foreground = state == AppLifecycleState.resumed);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entityId = widget.tile.entityId;
    final active =
        _foreground && TickerMode.valuesOf(context).enabled && entityId != null;
    final history = active
        ? ref.watch(entityHistoryProvider(entityId))
        : const AsyncData<EntityHistorySeries?>(null);
    final entities = active ? ref.watch(entitiesProvider) : null;
    final entity = entities == null || entities.isLoading || entities.hasError
        ? null
        : entities.value?[entityId];
    final series = history.isLoading || history.hasError ? null : history.value;
    final deviceClass = entity?.attributes['device_class'];
    final color = entity == null
        ? CupertinoColors.systemTeal
        : categoryColorForDomain(
            context,
            entity.domain,
            deviceClass: deviceClass is String ? deviceClass : null,
          );
    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: Insets.tile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.tile.title ??
                  entity?.friendlyName ??
                  entityId ??
                  l10n.historyTileFallbackTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tileTitle,
            ),
            Expanded(
              child: history.isLoading
                  ? const Center(child: CupertinoActivityIndicator())
                  : history.hasError
                  ? Center(
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: active
                            ? () {
                                if (mounted &&
                                    _foreground &&
                                    TickerMode.valuesOf(context).enabled) {
                                  ref.invalidate(
                                    entityHistoryProvider(entityId),
                                  );
                                }
                              }
                            : null,
                        child: Text(
                          l10n.healthReadError,
                          style: AppText.caption2,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : series?.hasValues != true
                  ? Center(
                      child: Text(
                        l10n.historyTileNoData,
                        style: AppText.caption2,
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        titlesData: const FlTitlesData(show: false),
                        gridData: const FlGridData(show: false),
                        borderData: FlBorderData(show: false),
                        lineTouchData: const LineTouchData(enabled: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (final point in series!.points)
                                if (point.value == null)
                                  FlSpot.nullSpot
                                else
                                  FlSpot(
                                    point.time.millisecondsSinceEpoch
                                        .toDouble(),
                                    point.value!,
                                  ),
                            ],
                            isCurved: false,
                            color: color,
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                      duration: Duration.zero,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
