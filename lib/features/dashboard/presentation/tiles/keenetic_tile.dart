import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../keenetic/presentation/keenetic_metric_detail_screen.dart';
import '../../../keenetic/presentation/keenetic_metric_presentation.dart';
import '../../../keenetic/presentation/keenetic_metric_view.dart';
import '../../../keenetic/providers/keenetic_telemetry_providers.dart';
import '../../domain/tile_config.dart';

class KeeneticTile extends StatelessWidget {
  const KeeneticTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final request = KeeneticMetricRequest(
      tile.keeneticMetric ?? KeeneticMetricKind.routerResources,
      interfaceId: tile.keeneticInterfaceId,
    );
    final title = tile.title ?? keeneticMetricTitle(l10n, request.kind);
    return KeeneticMetricView(
      request: request,
      builder: (context, reading, configured) {
        final snapshot = reading.isLoading || reading.hasError
            ? null
            : reading.value;
        final presentation = snapshot == null
            ? null
            : KeeneticMetricPresentation.from(snapshot, request, l10n);
        final issue = reading.hasError
            ? l10n.healthReadError
            : presentation?.issue == null
            ? null
            : keeneticReadFailureLabel(l10n, presentation!.issue!);
        return CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            if (context.mounted) {
              Navigator.push(
                context,
                CupertinoPageRoute<void>(
                  builder: (_) => KeeneticMetricDetailScreen(tile: tile),
                ),
              );
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: CupertinoColors.secondarySystemGroupedBackground
                  .resolveFrom(context),
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(keeneticMetricIcon(request.kind), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileTitle.copyWith(
                          color: CupertinoColors.label.resolveFrom(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (reading.isLoading) {
                        return const Center(
                          child: CupertinoActivityIndicator(),
                        );
                      }
                      if (!configured ||
                          (issue != null && presentation?.readAt == null)) {
                        return Text(
                          issue ?? l10n.commonNotConnected,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.footnote.copyWith(
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        );
                      }
                      final lines =
                          presentation?.lines ?? const <KeeneticMetricLine>[];
                      final rowHeight =
                          MediaQuery.textScalerOf(context)
                                  .scale(AppText.footnote.fontSize!) *
                              1.4 +
                          8;
                      final count = (constraints.maxHeight / rowHeight)
                          .floor()
                          .clamp(0, lines.length + 1);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (issue != null && count > 0)
                            SizedBox(
                              height: rowHeight,
                              child: Text(
                                presentation!.stale
                                    ? l10n.keeneticMetricStale
                                    : issue,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.footnote.copyWith(
                                  color: CupertinoColors.systemOrange
                                      .resolveFrom(context),
                                ),
                              ),
                            ),
                          for (final line in lines.take(
                            (count - (issue == null ? 0 : 1)).clamp(
                              0,
                              lines.length,
                            ),
                          ))
                            SizedBox(
                              height: rowHeight,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      line.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.footnote.copyWith(
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      line.value,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.footnote.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: CupertinoColors.label
                                            .resolveFrom(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
