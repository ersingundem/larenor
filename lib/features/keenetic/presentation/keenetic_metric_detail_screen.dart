import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../dashboard/domain/tile_config.dart';
import '../providers/keenetic_telemetry_providers.dart';
import 'keenetic_metric_presentation.dart';
import 'keenetic_metric_view.dart';

class KeeneticMetricDetailScreen extends ConsumerWidget {
  const KeeneticMetricDetailScreen({super.key, required this.tile});
  final TileConfig tile;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final request = KeeneticMetricRequest(
      tile.keeneticMetric ?? KeeneticMetricKind.routerResources,
      interfaceId: tile.keeneticInterfaceId,
    );
    final title = tile.title ?? keeneticMetricTitle(l10n, request.kind);
    return ServiceRootScaffold(
      title: title,
      slivers: [
        SliverToBoxAdapter(
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: KeeneticMetricView(
                  request: request,
                  builder: (context, reading, configured) {
                    final snapshot = reading.isLoading || reading.hasError
                        ? null
                        : reading.value;
                    final presentation = snapshot == null
                        ? null
                        : KeeneticMetricPresentation.from(
                            snapshot,
                            request,
                            l10n,
                          );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SettingsSection(
                          header: Semantics(
                            key: const ValueKey('keenetic-metric-header'),
                            header: true,
                            child: Text(title),
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.keeneticMetricReadHint,
                                    style: AppText.subhead,
                                  ),
                                  const SizedBox(height: 12),
                                  if (reading.isLoading)
                                    const CupertinoActivityIndicator()
                                  else if (reading.hasError)
                                    Text(l10n.healthReadError)
                                  else if (!configured)
                                    Text(l10n.commonNotConnected),
                                  if (presentation?.issue != null)
                                    Text(
                                      keeneticReadFailureLabel(
                                        l10n,
                                        presentation!.issue!,
                                      ),
                                    ),
                                  if (presentation?.stale == true)
                                    Text(l10n.keeneticMetricStale),
                                  if (snapshot?.isPaused == true)
                                    Text(l10n.keeneticMetricPaused),
                                  if (presentation?.awaitingSample == true)
                                    Text(l10n.keeneticSamplePending),
                                  if (presentation?.readAt != null)
                                    Text(
                                      l10n.healthLastSuccessfulRead(
                                        DateFormat.yMd(l10n.localeName)
                                            .add_Hms()
                                            .format(
                                              presentation!.readAt!.toLocal(),
                                            ),
                                      ),
                                      style: AppText.footnote,
                                    ),
                                ],
                              ),
                            ),
                            SettingsActionTile(
                              buttonKey: const ValueKey(
                                'keenetic-metric-refresh',
                              ),
                              title: Text(l10n.commonRefresh),
                              onTap:
                                  configured &&
                                      snapshot != null &&
                                      snapshot.isRefreshing == false &&
                                      !snapshot.isPaused
                                  ? () => ref
                                        .read(
                                          keeneticTelemetryControllerProvider,
                                        )
                                        .refresh()
                                  : null,
                            ),
                          ],
                        ),
                        if (presentation != null)
                          for (final line in presentation.lines)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: CupertinoColors
                                      .secondarySystemGroupedBackground
                                      .resolveFrom(context),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(line.label, style: AppText.footnote),
                                    const SizedBox(height: 6),
                                    Text(line.value, style: AppText.headline),
                                  ],
                                ),
                              ),
                            ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
