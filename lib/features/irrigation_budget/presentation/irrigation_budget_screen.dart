import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/irrigation_budget_controller.dart';
import '../domain/irrigation_budget_models.dart';

class IrrigationBudgetScreen extends StatefulWidget {
  const IrrigationBudgetScreen({super.key, required this.controller});
  final IrrigationBudgetController controller;

  @override
  State<IrrigationBudgetScreen> createState() => _IrrigationBudgetScreenState();
}

class _IrrigationBudgetScreenState extends State<IrrigationBudgetScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.snapshot == null)
        widget.controller.load();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return ServiceRootScaffold(
      title: l10n.irrigationBudgetTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.irrigationBudgetStatus),
            footer: Text(l10n.irrigationBudgetManualBoundary),
            children: [
              _Status(controller: controller),
              SettingsActionTile(
                buttonKey: const ValueKey('irrigation-budget-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.irrigationBudgetRefresh),
                onTap: controller.state == IrrigationBudgetViewState.loading
                    ? null
                    : controller.load,
              ),
            ],
          ),
        ),
        if (snapshot != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Summary(snapshot: snapshot),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 900 ? 2 : 1;
                      final width =
                          (constraints.maxWidth - 16 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          for (final zone in snapshot.zones)
                            SizedBox(
                              width: width,
                              child: _ZoneCard(zone: zone),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller});
  final IrrigationBudgetController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = switch (controller.state) {
      IrrigationBudgetViewState.idle ||
      IrrigationBudgetViewState.loading => l10n.irrigationBudgetLoading,
      IrrigationBudgetViewState.ready => l10n.irrigationBudgetVerified,
      IrrigationBudgetViewState.failed => l10n.irrigationBudgetFailed,
      IrrigationBudgetViewState.stale => l10n.irrigationBudgetStale,
    };
    return Semantics(
      liveRegion: true,
      label: text,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (controller.state == IrrigationBudgetViewState.loading) ...[
                const CupertinoActivityIndicator(),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.snapshot});
  final IrrigationBudgetSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Card(
      label: l10n.irrigationBudgetSummary,
      children: [
        Text(
          l10n.irrigationBudgetSummary,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(l10n.irrigationRain(snapshot.rainMilliMm / 1000)),
        Text(l10n.irrigationDailyLimit(snapshot.dailyLimitMl / 1000)),
        Text(l10n.irrigationUsed(snapshot.usedMl / 1000)),
        Text(l10n.irrigationPlanned(snapshot.plannedMl / 1000)),
        const SizedBox(height: 8),
        Text(
          snapshot.forecastStatus == 'stale'
              ? l10n.irrigationForecastStale
              : l10n.irrigationForecastVerified,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({required this.zone});
  final IrrigationZoneBudget zone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = switch (zone.status) {
      'planned' => l10n.irrigationZonePlanned,
      'deferred' => l10n.irrigationZoneDeferred,
      'skipped' => l10n.irrigationZoneSkipped,
      _ => l10n.irrigationZoneBlocked,
    };
    final reason = switch (zone.reason) {
      'moisture_deficit' => l10n.irrigationReasonMoistureDeficit,
      'manual_override' => l10n.irrigationReasonManualOverride,
      'rain_forecast' => l10n.irrigationReasonRainForecast,
      'moisture_sufficient' => l10n.irrigationReasonMoistureSufficient,
      'budget_exhausted' => l10n.irrigationReasonBudgetExhausted,
      'leak_detected' => l10n.irrigationReasonLeakDetected,
      'freeze_risk' => l10n.irrigationReasonFreezeRisk,
      'wind_risk' => l10n.irrigationReasonWindRisk,
      'safety_stale' => l10n.irrigationReasonSafetyStale,
      _ => l10n.irrigationReasonSoilStale,
    };
    return _Card(
      label: '${zone.areaName}, ${zone.plantName}, $status',
      children: [
        Text(
          zone.areaName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        Text(zone.plantName),
        const SizedBox(height: 8),
        Text(l10n.irrigationMoisture(zone.moisturePermille / 10)),
        Text(l10n.irrigationZoneStatus(status)),
        Text(reason),
        Text(l10n.irrigationDuration(zone.durationSeconds ~/ 60)),
        Text(l10n.irrigationWater(zone.estimatedWaterMl / 1000)),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
}
