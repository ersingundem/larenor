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
      if (mounted && widget.controller.snapshot == null) {
        widget.controller.load();
      }
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
                  if (snapshot.commandEndpointAvailable) ...[
                    const SizedBox(height: 16),
                    _ControlCard(controller: controller, snapshot: snapshot),
                  ],
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

class _ControlText {
  const _ControlText({
    required this.title,
    required this.boundary,
    required this.preview,
    required this.confirm,
    required this.stop,
    required this.previewReady,
    required this.result,
    required this.failed,
  });
  final String title, boundary, preview, confirm, stop;
  final String previewReady, result, failed;
}

_ControlText _controlText(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'tr'
    ? const _ControlText(
        title: 'Doğrulanmış sulama kontrolü',
        boundary: 'Planı inceleyin, sonra ayrıca onaylayın. Acil durdurma tüm bölgelerde kapalı vana ve durmuş akış kanıtı ister.',
        preview: 'Kontrol önizlemesi oluştur',
        confirm: 'Sulamayı onayla',
        stop: 'Tüm vanaları güvenle durdur',
        previewReady: 'Önizleme hazır',
        result: 'Sonuç',
        failed: 'Kontrol isteği doğrulanamadı. Durumu yenileyin.',
      )
    : const _ControlText(
        title: 'Verified irrigation control',
        boundary: 'Review the plan, then confirm separately. Emergency stop requires closed-valve and stopped-flow evidence for every zone.',
        preview: 'Create control preview',
        confirm: 'Confirm watering',
        stop: 'Safely stop all valves',
        previewReady: 'Preview ready',
        result: 'Result',
        failed:
            'The control request could not be verified. Refresh the status.',
      );

class _ControlCard extends StatelessWidget {
  const _ControlCard({required this.controller, required this.snapshot});
  final IrrigationBudgetController controller;
  final IrrigationBudgetSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final text = _controlText(context);
    final preview = controller.preview;
    final result = controller.stopReceipt?.status ?? controller.receipt?.status;
    return _Card(
      label: text.title,
      children: [
        Text(
          text.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(text.boundary),
        if (controller.controlBusy) ...[
          const SizedBox(height: 12),
          const Center(child: CupertinoActivityIndicator()),
        ],
        if (controller.controlError != null) ...[
          const SizedBox(height: 12),
          Text(
            text.failed,
            style: const TextStyle(color: CupertinoColors.systemRed),
          ),
        ],
        if (preview != null) ...[
          const SizedBox(height: 12),
          Text('${text.previewReady}: ${preview.commandCount}'),
          Text(
            DateTime.fromMillisecondsSinceEpoch(
              preview.expiresAtMs,
              isUtc: true,
            ).toIso8601String(),
          ),
        ],
        if (result != null) ...[
          const SizedBox(height: 12),
          Text('${text.result}: $result'),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: CupertinoButton.filled(
            key: const ValueKey('irrigation-control-preview'),
            onPressed: controller.controlBusy || preview != null
                ? null
                : controller.createPreview,
            child: Text(text.preview),
          ),
        ),
        if (preview != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              key: const ValueKey('irrigation-control-confirm'),
              onPressed: controller.controlBusy
                  ? null
                  : controller.confirmPreview,
              child: Text(text.confirm),
            ),
          ),
        ],
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: CupertinoButton(
            key: const ValueKey('irrigation-control-stop'),
            color: CupertinoColors.systemRed,
            onPressed: controller.controlBusy ? null : controller.safeStop,
            child: Text(text.stop),
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
