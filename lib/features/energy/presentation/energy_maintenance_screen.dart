import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/integration_health_status.dart';
import '../../auth/providers/auth_providers.dart';
import '../../health/data/integration_health.dart';
import '../../proxmox/providers/proxmox_providers.dart';
import '../domain/energy_models.dart';
import '../domain/maintenance_models.dart';
import '../providers/energy_providers.dart';
import 'energy_labels.dart';

class EnergyMaintenanceScreen extends ConsumerStatefulWidget {
  const EnergyMaintenanceScreen({super.key});
  @override
  ConsumerState<EnergyMaintenanceScreen> createState() =>
      _EnergyMaintenanceScreenState();
}

class _EnergyMaintenanceScreenState
    extends ConsumerState<EnergyMaintenanceScreen> {
  MaintenanceScope _scope = MaintenanceScope.selected;
  final _expanded = <String>{};
  bool _foreground = true;
  late final AppLifecycleListener _lifecycle;
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
    final connection = ref.watch(connectionConfigProvider);
    final configured =
        !connection.isLoading &&
        !connection.hasError &&
        connection.value != null;
    final active = _foreground && TickerMode.valuesOf(context).enabled;
    // Keeping the inert controller preserves the selected range. Releasing the
    // stream's demand stops its timer and invalidates any in-flight response.
    final controller = configured ? ref.watch(energyControllerProvider) : null;
    final reading = active && configured
        ? ref.watch(energyProvider)
        : const AsyncData<EnergyViewState>(
            EnergyViewState(connectionConfigured: false),
          );
    final state = reading.isLoading || reading.hasError ? null : reading.value;
    final snapshot = state?.snapshot;
    final maintenance = active && configured
        ? ref.watch(maintenanceProvider(_scope))
        : null;
    ref.listen(connectionConfigProvider, (previous, next) {
      if (next.isLoading || next.hasError || previous?.value != next.value) {
        _expanded.clear();
      }
    });
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.energyTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _SectionHeading(
                    title: l10n.energyRecorded,
                    hint: l10n.energyHint,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final range in EnergyRange.values)
                              CupertinoButton(
                                key: ValueKey('energy-range-${range.name}'),
                                color: controller?.range == range
                                    ? CupertinoColors.activeBlue.resolveFrom(
                                        context,
                                      )
                                    : CupertinoColors.tertiarySystemFill
                                          .resolveFrom(context),
                                onPressed: !active || controller == null
                                    ? null
                                    : () {
                                        controller.setRange(range);
                                        setState(_expanded.clear);
                                      },
                                child: Text(
                                  range == EnergyRange.today
                                      ? l10n.todayTitle
                                      : l10n.energyLast7Days,
                                  style: AppText.subhead.copyWith(
                                    color: controller?.range == range
                                        ? CupertinoColors.white
                                        : CupertinoColors.label.resolveFrom(
                                            context,
                                          ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        IntegrationHealthStatus(
                          id: IntegrationId.ha,
                          configured: configured,
                        ),
                        if (connection.isLoading ||
                            (active &&
                                configured &&
                                (reading.isLoading ||
                                    (snapshot == null &&
                                        state?.failure == null))))
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: CupertinoActivityIndicator(),
                          ),
                        if (connection.hasError || reading.hasError)
                          Text(l10n.healthReadError)
                        else if (!configured && !connection.isLoading)
                          Text(l10n.commonNotConnected),
                        if (state?.failure != null)
                          Text(energyFailureLabel(l10n, state!.failure!)),
                        if (snapshot != null) ...[
                          if (snapshot.energyConfigured == false)
                            Text(l10n.energyNotConfigured),
                          if (snapshot.issues.isNotEmpty)
                            Text(l10n.energySourceIssue),
                          for (final failure
                              in snapshot.issues
                                  .map((issue) => issue.failure)
                                  .toSet())
                            Text(
                              energyFailureLabel(l10n, failure),
                              style: AppText.footnote,
                            ),
                          if (snapshot.energyConfigured == true &&
                              snapshot.meters.isEmpty)
                            Text(l10n.energyNoMeters),
                          if (snapshot.period != null)
                            Text(
                              '${snapshot.period!.days.first.localDate} — ${snapshot.period!.days.last.localDate} · ${snapshot.period!.timeZone}',
                              style: AppText.footnote,
                            ),
                          Text(
                            l10n.energyLastChecked(
                              DateFormat.yMd(l10n.localeName)
                                  .add_Hm()
                                  .format(snapshot.readAt.toLocal()),
                            ),
                            style: AppText.footnote,
                          ),
                        ],
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: !active || state?.isRefreshing == true
                              ? null
                              : () {
                                  if (connection.hasError) {
                                    ref.invalidate(connectionConfigProvider);
                                  } else {
                                    controller?.refresh();
                                  }
                                },
                          child: state?.isRefreshing == true
                              ? const CupertinoActivityIndicator()
                              : Text(l10n.commonRefresh),
                        ),
                      ],
                    ),
                  ),
                ),
                if (snapshot != null)
                  SliverList.builder(
                    itemCount: snapshot.meters.length,
                    itemBuilder: (context, index) {
                      final meter = snapshot.meters[index];
                      return _MeterCard(
                        meter: meter,
                        expanded: _expanded.contains(meter.definition.key),
                        onToggle: () => setState(() {
                          if (!_expanded.add(meter.definition.key)) {
                            _expanded.remove(meter.definition.key);
                          }
                        }),
                      );
                    },
                  ),
                if (snapshot?.costsConfigured == true)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        l10n.energyCurrencyHint,
                        style: AppText.footnote,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: _SectionHeading(
                    title: l10n.maintenanceTitle,
                    hint: l10n.maintenanceHint,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final scope in MaintenanceScope.values)
                          CupertinoButton(
                            key: ValueKey('maintenance-scope-${scope.name}'),
                            color: _scope == scope
                                ? CupertinoColors.activeBlue.resolveFrom(
                                    context,
                                  )
                                : CupertinoColors.tertiarySystemFill
                                      .resolveFrom(context),
                            onPressed: () => setState(() => _scope = scope),
                            child: Text(
                              scope == MaintenanceScope.selected
                                  ? l10n.maintenanceSelected
                                  : l10n.maintenanceAll,
                              style: AppText.subhead.copyWith(
                                color: _scope == scope
                                    ? CupertinoColors.white
                                    : CupertinoColors.label.resolveFrom(
                                        context,
                                      ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (maintenance?.isLoading == true)
                  const SliverToBoxAdapter(
                    child: Center(child: CupertinoActivityIndicator()),
                  )
                else if (maintenance?.readFailed == true)
                  SliverToBoxAdapter(child: _Message(l10n.healthReadError))
                else if (maintenance != null && maintenance.items.isEmpty)
                  SliverToBoxAdapter(
                    child: _Message(
                      maintenance.checkedEntities == 0
                          ? l10n.maintenanceNoSelection
                          : l10n.maintenanceNone,
                    ),
                  ),
                if (maintenance != null)
                  SliverList.builder(
                    itemCount: maintenance.items.length,
                    itemBuilder: (context, index) {
                      final item = maintenance.items[index];
                      return _Surface(
                        child: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => context.push(
                            Uri(pathSegments: ['', 'entities', item.entityId])
                                .toString(),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.kinds.contains(MaintenanceKind.lowBattery)
                                    ? CupertinoIcons.battery_25
                                    : CupertinoIcons.exclamationmark_circle,
                                color: CupertinoColors.systemOrange.resolveFrom(
                                  context,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      style: AppText.headline.copyWith(
                                        color: CupertinoColors.label
                                            .resolveFrom(context),
                                      ),
                                    ),
                                    Text(
                                      item.kinds
                                          .map(
                                            (kind) => maintenanceKindLabel(
                                              l10n,
                                              kind,
                                            ),
                                          )
                                          .join(' · '),
                                      style: AppText.footnote.copyWith(
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                      ),
                                    ),
                                    if (item.batteryPercent != null)
                                      Text(
                                        '${NumberFormat('0.#', l10n.localeName).format(item.batteryPercent)}%',
                                        style: AppText.footnote,
                                      ),
                                  ],
                                ),
                              ),
                              const Icon(
                                CupertinoIcons.chevron_forward,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                if (active) const _ServerCapacity(),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MeterCard extends StatelessWidget {
  const _MeterCard({
    required this.meter,
    required this.expanded,
    required this.onToggle,
  });
  final EnergyMeterReading meter;
  final bool expanded;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String value(double? number) =>
        number == null || !number.isFinite || meter.unit == null
        ? l10n.commonUnknown
        : '${NumberFormat('0.##', l10n.localeName).format(number)} ${meter.unit}';
    return _Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(energyRoleLabel(l10n, meter.role), style: AppText.footnote),
          const SizedBox(height: 8),
          Text(meter.name, style: AppText.headline),
          const SizedBox(height: 8),
          Text(value(meter.reportedTotal), style: AppText.title1),
          if (meter.issues.isNotEmpty ||
              meter.coverageIssues.any(
                (issue) => issue != EnergyCoverageIssue.ongoing,
              ))
            Text(
              l10n.energyPartial,
              style: AppText.footnote.copyWith(
                color: CupertinoColors.systemOrange.resolveFrom(context),
              ),
            ),
          if (meter.includedInStatisticId != null)
            Text(
              '${l10n.energyIncludedIn}: ${meter.includedInStatisticId}',
              style: AppText.footnote,
            ),
          for (final label in energyCoverageLabels(l10n, meter.coverageIssues))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(label, style: AppText.footnote),
            ),
          for (final failure
              in meter.issues.map((issue) => issue.failure).toSet())
            Text(energyFailureLabel(l10n, failure), style: AppText.footnote),
          CupertinoButton(
            key: ValueKey('energy-meter-${meter.definition.key}'),
            padding: EdgeInsets.zero,
            onPressed: onToggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(l10n.energyDaily)),
                const SizedBox(width: 8),
                Icon(
                  expanded
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  size: 16,
                ),
              ],
            ),
          ),
          if (expanded) ...[
            Text(meter.statisticId, style: AppText.caption1),
            for (final day in meter.daily)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 16,
                      children: [
                        Text(day.window.localDate, style: AppText.subhead),
                        Text(value(day.reportedValue), style: AppText.headline),
                      ],
                    ),
                    for (final label in energyCoverageLabels(l10n, day.issues))
                      Text(label, style: AppText.footnote),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ServerCapacity extends ConsumerWidget {
  const _ServerCapacity();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(proxmoxConnectionProvider);
    final l10n = AppLocalizations.of(context);
    if (config.hasError) {
      return SliverToBoxAdapter(
        child: _Message('${l10n.maintenanceCapacity}: ${l10n.healthReadError}'),
      );
    }
    if (config.isLoading || config.value == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final nodes = ref.watch(proxmoxNodesProvider);
    final values = nodes.isLoading || nodes.hasError ? null : nodes.value;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeading(
                title: l10n.maintenanceCapacity,
                hint: l10n.maintenanceCapacityHint,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: IntegrationHealthStatus(
                  id: IntegrationId.proxmox,
                  configured: true,
                ),
              ),
              if (nodes.isLoading)
                const Center(child: CupertinoActivityIndicator())
              else if (nodes.hasError)
                _Message(l10n.healthReadError)
              else if (values?.isEmpty == true)
                _Message(l10n.maintenanceNoNodes),
            ],
          ),
        ),
        if (values != null)
          SliverList.builder(
            itemCount: values.length,
            itemBuilder: (context, index) {
              final node = values[index];
              return _Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(node.name, style: AppText.headline),
                    if (node.status == 'offline')
                      Text(l10n.maintenanceOffline, style: AppText.footnote)
                    else if (!node.isOnline)
                      Text(l10n.commonUnknown, style: AppText.footnote),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 24,
                      runSpacing: 10,
                      children: [
                        _CapacityValue(
                          label: l10n.maintenanceCpu,
                          fraction: node.isOnline ? node.cpuFraction : null,
                        ),
                        _CapacityValue(
                          label: l10n.maintenanceMemory,
                          fraction: node.isOnline ? node.memFraction : null,
                        ),
                        _CapacityValue(
                          label: l10n.maintenanceRootDisk,
                          fraction: node.isOnline ? node.diskFraction : null,
                        ),
                      ],
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => context.push('/system/proxmox'),
                      child: const Text('Proxmox'),
                    ),
                  ],
                ),
              );
            },
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: nodes.isLoading
                  ? null
                  : () => ref.invalidate(proxmoxNodesProvider),
              child: Text(l10n.commonRefresh),
            ),
          ),
        ),
      ],
    );
  }
}

class _CapacityValue extends StatelessWidget {
  const _CapacityValue({required this.label, required this.fraction});
  final String label;
  final double? fraction;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final number = fraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.footnote),
        Text(
          number == null || !number.isFinite || number < 0 || number > 1
              ? l10n.commonUnknown
              : '${NumberFormat('0.#', l10n.localeName).format(number * 100)}%',
          style: AppText.title3,
        ),
      ],
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.hint});
  final String title, hint;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.title2),
        const SizedBox(height: 8),
        Text(
          hint,
          style: AppText.subhead.copyWith(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(message, style: AppText.subhead),
  );
}
