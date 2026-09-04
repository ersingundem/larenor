import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';

class HistoryTile extends ConsumerStatefulWidget {
  const HistoryTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  ConsumerState<HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends ConsumerState<HistoryTile> {
  List<FlSpot>? _spots;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entityId = widget.tile.entityId;
    final rest = ref.read(haRestClientProvider);
    if (rest == null || entityId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final start = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 24))
          .toIso8601String();
      final result = await rest.getJson(
        '/api/history/period/$start?filter_entity_id=$entityId&minimal_response',
      );

      final series = (result is List && result.isNotEmpty)
          ? result.first as List<dynamic>?
          : null;

      final spots = <FlSpot>[];
      if (series != null) {
        for (final point in series) {
          final map = point as Map<String, dynamic>;
          final value = double.tryParse('${map['state']}');
          final changed = DateTime.tryParse(
            map['last_changed'] as String? ?? '',
          );
          if (value == null || changed == null) continue;
          spots.add(FlSpot(changed.millisecondsSinceEpoch.toDouble(), value));
        }
      }

      if (mounted) {
        setState(() {
          _spots = spots;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entity = ref.watch(entitiesProvider).value?[widget.tile.entityId];

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
              entity?.friendlyName ??
                  widget.tile.entityId ??
                  AppLocalizations.of(context).historyTileFallbackTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tileTitle,
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : (_spots == null || _spots!.isEmpty)
                  ? Center(
                      child: Text(
                        _error ??
                            AppLocalizations.of(context).historyTileNoData,
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
                            spots: _spots!,
                            isCurved: true,
                            color: entity == null
                                ? CupertinoColors.systemTeal
                                : categoryColorForDomain(
                                    context,
                                    entity.domain,
                                    deviceClass:
                                        entity.attributes['device_class']
                                            as String?,
                                  ),
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
