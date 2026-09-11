import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../navigation/search/domain/local_search_index.dart';
import '../../../today/domain/today_daily_summary.dart';
import '../../../today/providers/today_providers.dart';
import '../../../today/presentation/today_daily_summary_card.dart';
import '../../domain/tile_config.dart';

/// A compact, read-only rendering of one Today section. Actions are limited to
/// opening Today and explicitly refreshing its existing read controller.
class TodayDashboardCard extends StatelessWidget {
  const TodayDashboardCard({
    super.key,
    required this.section,
    required this.loading,
    required this.offline,
    required this.query,
    required this.onOpen,
    required this.onRefresh,
  });

  final TodayDailySummarySection? section;
  final bool loading;
  final bool offline;
  final String query;
  final VoidCallback? onOpen;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = section == null
        ? l10n.todayTitle
        : todaySummaryTitle(l10n, section!.kind);
    final state = loading
        ? l10n.commonLoading
        : offline || section == null
        ? l10n.todaySummaryOffline
        : todaySummaryStateLabel(l10n, section!);
    final foldedQuery = foldSearchText(query);
    final entries = (section?.entries ?? const <TodayDailySummaryEntry>[])
        .where(
          (entry) =>
              foldedQuery.isEmpty ||
              foldSearchText('${entry.title} ${entry.supportingText ?? ''}')
                  .contains(foldedQuery),
        )
        .take(2)
        .toList(growable: false);
    final warning =
        loading ||
        offline ||
        section == null ||
        switch (section!.state) {
          TodayDailySummaryState.current ||
          TodayDailySummaryState.empty => false,
          _ => true,
        };
    final semantics = [
      l10n.todayTitle,
      title,
      state,
      if (query.isNotEmpty) '${l10n.commonSearch}: $query',
      ...entries.map((entry) => entry.title),
    ].join('. ');
    return Semantics(
      key: const ValueKey('today-dashboard-card'),
      container: true,
      explicitChildNodes: true,
      label: semantics,
      child: Container(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(CupertinoIcons.calendar_today, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle.copyWith(
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('today-dashboard-open'),
                  minimumSize: const Size.square(48),
                  padding: EdgeInsets.zero,
                  onPressed: onOpen,
                  child: Semantics(
                    button: true,
                    label: l10n.todayViewAll(
                      section?.totalCount ?? section?.entries.length ?? 0,
                    ),
                    child: const ExcludeSemantics(
                      child: Icon(CupertinoIcons.arrow_up_right_square),
                    ),
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('today-dashboard-refresh'),
                  minimumSize: const Size.square(48),
                  padding: EdgeInsets.zero,
                  onPressed: onRefresh,
                  child: Semantics(
                    button: true,
                    label: l10n.commonRefresh,
                    child: ExcludeSemantics(
                      child: loading
                          ? const CupertinoActivityIndicator()
                          : const Icon(CupertinoIcons.refresh),
                    ),
                  ),
                ),
              ],
            ),
            Text(
              state,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.footnote.copyWith(
                color: warning
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            if (query.isNotEmpty)
              Text(
                '${l10n.commonSearch}: $query',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.footnote,
              ),
            if (entries.isNotEmpty)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final rowHeight =
                        MediaQuery.textScalerOf(context)
                            .scale(AppText.footnote.fontSize!) *
                        1.35;
                    final count = (constraints.maxHeight / rowHeight)
                        .floor()
                        .clamp(0, entries.length);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final entry in entries.take(count))
                          SizedBox(
                            height: rowHeight,
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.footnote.copyWith(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
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
  }
}

class TodayTile extends ConsumerStatefulWidget {
  const TodayTile({super.key, required this.tile});
  final TileConfig tile;

  @override
  ConsumerState<TodayTile> createState() => _TodayTileState();
}

class _TodayTileState extends ConsumerState<TodayTile> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  bool _refreshing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        final foreground = state == AppLifecycleState.resumed;
        if (_foreground == foreground) return;
        if (!foreground) _generation++;
        setState(() {
          _foreground = foreground;
          if (!foreground) _refreshing = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _generation++;
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!_foreground || _refreshing) return;
    final generation = _generation;
    setState(() => _refreshing = true);
    try {
      final controller = ref.read(todayControllerProvider);
      if (controller == null) {
        ref.invalidate(todayProvider);
      } else {
        await controller.refresh();
      }
    } catch (_) {
      // Provider state owns the localized, secret-free read failure.
    } finally {
      if (mounted && _foreground && generation == _generation) {
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    final reading = active ? ref.watch(todayProvider) : null;
    final snapshot = reading?.value;
    final selection = ref.watch(todaySummarySelectionProvider);
    final storedKind = TodayDailySummaryKind.values
        .where((candidate) => candidate.name == widget.tile.todaySection)
        .firstOrNull;
    final hasPersonalContext =
        storedKind != null && widget.tile.todayQuery != null;
    final kind = hasPersonalContext
        ? storedKind
        : selection?.kind ?? TodayDailySummaryKind.shopping;
    final summary = snapshot?.configured == true
        ? TodayDailySummary.fromSnapshot(snapshot!)
        : null;
    final section = summary?.sections
        .where((candidate) => candidate.kind == kind)
        .firstOrNull;
    return TodayDashboardCard(
      section: section,
      loading: _refreshing || reading?.isLoading == true,
      offline: reading?.hasError == true || snapshot?.configured != true,
      query: hasPersonalContext
          ? widget.tile.todayQuery!
          : selection?.query ?? '',
      onOpen: active ? () => context.go('/today') : null,
      onRefresh: active && !_refreshing ? _refresh : null,
    );
  }
}
