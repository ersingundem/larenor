import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/theme/typography.dart';
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
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(tile.title ?? keeneticMetricTitle(l10n, request.kind)),
      ),
      child: SafeArea(
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
                    : KeeneticMetricPresentation.from(snapshot, request, l10n);
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
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
                                      .format(presentation!.readAt!.toLocal()),
                                ),
                                style: AppText.footnote,
                              ),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed:
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
                              child: Text(l10n.commonRefresh),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (presentation != null)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        sliver: SliverList.builder(
                          itemCount: presentation.lines.length,
                          itemBuilder: (context, index) {
                            final line = presentation.lines[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
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
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
