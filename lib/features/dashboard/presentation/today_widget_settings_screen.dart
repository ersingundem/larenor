import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../today/domain/today_daily_summary.dart';
import '../../today/presentation/today_daily_summary_card.dart';
import '../domain/tile_config.dart';
import 'dashboard_edit_guard.dart';

/// Edits only the local Today tile context. It never initializes a Today/HA
/// reader and returns a draft for the dashboard's guarded write queue.
class TodayWidgetSettingsScreen extends ConsumerStatefulWidget {
  const TodayWidgetSettingsScreen({super.key, required this.initialTile});
  final TileConfig initialTile;

  @override
  ConsumerState<TodayWidgetSettingsScreen> createState() =>
      _TodayWidgetSettingsScreenState();
}

class _TodayWidgetSettingsScreenState
    extends DashboardEditState<TodayWidgetSettingsScreen> {
  late TodayDailySummaryKind _kind;
  late final TextEditingController _query;
  bool _expired = false;
  bool _returned = false;

  @override
  void initState() {
    super.initState();
    final tile = widget.initialTile;
    _expired = tile.type != TileType.today;
    _kind =
        TodayDailySummaryKind.values
            .where((candidate) => candidate.name == tile.todaySection)
            .firstOrNull ??
        TodayDailySummaryKind.shopping;
    _query = TextEditingController(text: _clean(tile.todayQuery ?? ''));
  }

  @override
  void invalidateDashboardInteraction() {
    _expired = true;
    _query.clear();
  }

  bool _current(int generation) =>
      !_expired &&
      !_returned &&
      interactionCurrent(generation) &&
      ModalRoute.of(context)?.isCurrent == true;

  void _save(int generation) {
    if (!_current(generation)) return;
    _returned = true;
    Navigator.pop(
      context,
      widget.initialTile.copyWith(
        todaySection: _kind.name,
        todayQuery: _query.text,
      ),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchDashboardAccount();
    final l10n = AppLocalizations.of(context);
    final generation = interactionGeneration;
    return ServiceRootScaffold(
      title: l10n.todayTitle,
      trailing: CupertinoButton(
        key: const ValueKey('today-widget-cancel'),
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        onPressed: () => closeDashboardModal(context),
        child: Text(l10n.commonCancel),
      ),
      slivers: [
        if (_expired)
          SliverFilledMessage(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.dashboardWidgetPickerExpired),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Column(
                  children: [
                    SettingsSection(
                      header: Semantics(
                        key: const ValueKey('today-widget-title'),
                        container: true,
                        header: true,
                        child: Text(l10n.todayTitle),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final kind in TodayDailySummaryKind.values)
                                Semantics(
                                  key: ValueKey(
                                    'today-widget-section-${kind.name}',
                                  ),
                                  button: true,
                                  selected: kind == _kind,
                                  label: todaySummaryTitle(l10n, kind),
                                  child: CupertinoButton(
                                    minimumSize: const Size(48, 48),
                                    color: kind == _kind
                                        ? CupertinoTheme.of(context)
                                              .primaryColor
                                        : CupertinoColors
                                              .tertiarySystemGroupedBackground
                                              .resolveFrom(context),
                                    onPressed: dashboardAction(
                                      () => setState(() => _kind = kind),
                                    ),
                                    child: ExcludeSemantics(
                                      child: Text(
                                        todaySummaryTitle(l10n, kind),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SettingsSection(
                      header: Semantics(
                        key: const ValueKey('today-widget-search-title'),
                        container: true,
                        header: true,
                        child: Text(l10n.commonSearch),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: CupertinoSearchTextField(
                            key: const ValueKey('today-widget-query'),
                            controller: _query,
                            placeholder: l10n.commonSearch,
                            onSubmitted: (_) => _save(generation),
                            onChanged: (value) {
                              final clean = _clean(value);
                              if (clean == value) return;
                              _query.value = TextEditingValue(
                                text: clean,
                                selection: TextSelection.collapsed(
                                  offset: clean.length,
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    SettingsSection(
                      children: [
                        SettingsActionTile(
                          buttonKey: const ValueKey('today-widget-save'),
                          title: Text(l10n.commonSave),
                          onTap: dashboardAction(() => _save(generation)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _clean(String value) => value
    .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
    .characters
    .take(128)
    .toString();
