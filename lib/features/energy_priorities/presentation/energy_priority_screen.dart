import 'package:flutter/cupertino.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/energy_priority_controller.dart';
import '../domain/energy_priority_models.dart';

final class _Text {
  const _Text(this.value);
  factory _Text.of(BuildContext context) => _Text(AppLocalizations.of(context));
  final AppLocalizations value;
  String get title => value.energyPriorityTitle;
  String get advisory => value.energyPriorityAdvisory;
  String get unavailable => value.energyPriorityUnavailable;
  String get solar => value.energyPrioritySolar;
  String get load => value.energyPriorityLoad;
  String get battery => value.energyPriorityBattery;
  String get reserve => value.energyPriorityReserve;
  String get preview => value.energyPriorityPreview;
  String get confirm => value.energyPriorityConfirm;
  String applyReserve(int percent) => value.energyPriorityApplyReserve(percent);
  String get confirmReserve => value.energyPriorityConfirmReserve;
  String get reserveOnly => value.energyPriorityReserveOnly;
  String get cancel => value.energyPriorityCancel;
  String get refresh => value.energyPriorityRefresh;
  String get loading => value.energyPriorityLoading;
  String get failed => value.energyPriorityFailed;
  String get stale => value.energyPriorityStale;
  String get verified => value.energyPriorityVerified;
  String get timeline => value.energyPriorityTimeline;
  String get freshness => value.energyPriorityFreshness;
  String get charge => value.energyPriorityCharge;
  String get discharge => value.energyPriorityDischarge;
  String get hold => value.energyPriorityHold;
  String get noCurrentAction => value.energyPriorityNoCurrentAction;
  String get setupTitle => value.energyPrioritySetupTitle;
  String get setupDescription => value.energyPrioritySetupDescription;
  String get setupSource => value.energyPrioritySetupSource;
  String get setupEntity => value.energyPrioritySetupEntity;
  String get setupAccept => value.energyPrioritySetupAccept;
  String get setupNoSource => value.energyPrioritySetupNoSource;
  String get setupFailed => value.energyPrioritySetupFailed;
  String get setupRefresh => value.energyPrioritySetupRefresh;
  String get backtestTitle => value.energyPriorityBacktestTitle;
  String get backtestLoading => value.energyPriorityBacktestLoading;
  String get backtestUnavailable => value.energyPriorityBacktestUnavailable;
  String get backtestMultipleBatteries =>
      value.energyPriorityBacktestMultipleBatteries;
  String backtestBelow(int samples) =>
      value.energyPriorityBacktestBelow(samples);
  String backtestClear(int samples) =>
      value.energyPriorityBacktestClear(samples);
  String backtestUncertain(int samples) =>
      value.energyPriorityBacktestUncertain(samples);
  String backtestMinimum(String percent) =>
      value.energyPriorityBacktestMinimum(percent);
  String get backtestForecastComplete =>
      value.energyPriorityBacktestForecastComplete;
  String get backtestForecastPartial =>
      value.energyPriorityBacktestForecastPartial;
  String get backtestForecastMissing =>
      value.energyPriorityBacktestForecastMissing;
  String get backtestLimits => value.energyPriorityBacktestLimits;
}

class EnergyPriorityScreen extends StatefulWidget {
  const EnergyPriorityScreen({super.key, required this.controller});
  final EnergyPriorityController controller;
  @override
  State<EnergyPriorityScreen> createState() => _EnergyPriorityScreenState();
}

class _EnergyPriorityScreenState extends State<EnergyPriorityScreen> {
  AppInteractionController? _interaction;
  final _reserveEntity = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next?..addListener(_interactionChanged);
    _interactionChanged();
  }

  void _interactionChanged() =>
      widget.controller.setInteractive(_interaction?.active ?? true);
  void _changed() {
    if (!mounted) return;
    if (widget.controller.snapshot?.canSetReserve == true &&
        _reserveEntity.text.isNotEmpty) {
      _reserveEntity.clear();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _interaction?.removeListener(_interactionChanged);
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    _reserveEntity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _Text.of(context);
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final currentAction = snapshot?.actionableAt(DateTime.now());
    return ServiceRootScaffold(
      title: text.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(text.advisory),
            children: [
              _Status(controller: controller, text: text),
              if (snapshot != null) _Summary(snapshot: snapshot, text: text),
              if (snapshot != null)
                _ReserveBacktest(controller: controller, text: text),
              if (snapshot != null) _Timeline(snapshot: snapshot, text: text),
              if (snapshot != null && !snapshot.canControl)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(text.unavailable),
                ),
              if (snapshot != null &&
                  snapshot.canAdminister &&
                  controller.canConfigureReserve &&
                  !snapshot.canSetReserve)
                _ReserveSourceSetup(
                  controller: controller,
                  entityController: _reserveEntity,
                  text: text,
                  onEntityChanged: () => setState(() {}),
                ),
              if (snapshot?.canSetReserve == true)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(text.reserveOnly),
                ),
              if (snapshot != null &&
                  snapshot.canSetReserve &&
                  controller.pending == null &&
                  controller.reservePending == null)
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-preview-reserve'),
                  leading: const Icon(CupertinoIcons.shield_lefthalf_fill),
                  title: Text(text.applyReserve(snapshot.reservePercent)),
                  onTap: controller.canAct ? controller.previewReserve : null,
                ),
              if (snapshot != null &&
                  currentAction != null &&
                  snapshot.supports(currentAction) &&
                  snapshot.canControl &&
                  controller.pending == null &&
                  controller.reservePending == null)
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-preview-action'),
                  leading: const Icon(CupertinoIcons.bolt_circle),
                  title: Text(text.preview),
                  onTap: controller.canAct
                      ? () => controller.preview(currentAction)
                      : null,
                ),
              if (snapshot != null &&
                  snapshot.canControl &&
                  !snapshot.canSetReserve &&
                  currentAction == null &&
                  controller.pending == null &&
                  controller.reservePending == null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(text.noCurrentAction),
                ),
              if (controller.pending != null) ...[
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-confirm-action'),
                  leading: const Icon(CupertinoIcons.check_mark_circled),
                  title: Text(text.confirm),
                  onTap: controller.canAct ? controller.confirm : null,
                ),
              ],
              if (controller.reservePending != null)
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-confirm-reserve'),
                  leading: const Icon(CupertinoIcons.check_mark_circled),
                  title: Text(text.confirmReserve),
                  onTap: controller.canAct ? controller.confirmReserve : null,
                ),
              if (controller.pending != null ||
                  controller.reservePending != null)
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-cancel-preview'),
                  leading: const Icon(CupertinoIcons.clear_circled),
                  title: Text(text.cancel),
                  onTap: controller.canAct ? controller.cancelPreview : null,
                ),
              if (controller.state == EnergyPriorityViewState.failed ||
                  controller.state == EnergyPriorityViewState.stale)
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-priority-refresh'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(text.refresh),
                  onTap: controller.load,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReserveBacktest extends StatelessWidget {
  const _ReserveBacktest({required this.controller, required this.text});
  final EnergyPriorityController controller;
  final _Text text;

  @override
  Widget build(BuildContext context) {
    final value = controller.reserveBacktest;
    final status = value == null
        ? controller.reserveBacktestBusy
              ? text.backtestLoading
              : text.backtestUnavailable
        : value.uncertaintyReasons.contains('multiple_battery_series')
        ? text.backtestMultipleBatteries
        : switch (value.observedStatus) {
            EnergyReserveBacktestStatus.sampleBelowReserve =>
              text.backtestBelow(value.belowReserveSampleCount),
            EnergyReserveBacktestStatus.noSampleBelowReserve =>
              text.backtestClear(value.sampleCount),
            EnergyReserveBacktestStatus.uncertain => text.backtestUncertain(
              value.sampleCount,
            ),
          };
    final forecast = value == null
        ? null
        : switch (value.forecastCoverage) {
            EnergyReserveHistoryCoverage.complete =>
              text.backtestForecastComplete,
            EnergyReserveHistoryCoverage.partial =>
              text.backtestForecastPartial,
            EnergyReserveHistoryCoverage.missing =>
              text.backtestForecastMissing,
          };
    return Padding(
      key: const ValueKey('energy-reserve-backtest'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            text.backtestTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(status),
          if (value?.minimumObservedSocPercent != null)
            Text(
              text.backtestMinimum(
                value!.minimumObservedSocPercent!.toStringAsFixed(1),
              ),
            ),
          if (forecast != null) Text(forecast),
          const SizedBox(height: 6),
          Text(text.backtestLimits, style: const TextStyle(fontSize: 13)),
          if (controller.reserveBacktestBusy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: CupertinoActivityIndicator(),
            ),
        ],
      ),
    );
  }
}

class _ReserveSourceSetup extends StatelessWidget {
  const _ReserveSourceSetup({
    required this.controller,
    required this.entityController,
    required this.text,
    required this.onEntityChanged,
  });

  final EnergyPriorityController controller;
  final TextEditingController entityController;
  final _Text text;
  final VoidCallback onEntityChanged;

  @override
  Widget build(BuildContext context) {
    final sources = controller.reserveSources;
    final validEntity = RegExp(r'^number\.[a-z0-9_]{1,249}$')
        .hasMatch(entityController.text);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            text.setupTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(text.setupDescription),
          const SizedBox(height: 12),
          if (controller.reserveSetupBusy)
            const Center(child: CupertinoActivityIndicator())
          else if (sources.isEmpty)
            Text(text.setupNoSource)
          else ...[
            Semantics(
              label: text.setupSource,
              child: SizedBox(
                height: (sources.length.clamp(1, 3) * 44).toDouble(),
                child: CupertinoPicker(
                  key: const ValueKey('energy-reserve-source-picker'),
                  itemExtent: 44,
                  onSelectedItemChanged: (index) =>
                      controller.selectReserveSource(sources[index]),
                  children: [
                    for (final source in sources)
                      Center(child: Text(source.name)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            CupertinoTextField(
              key: const ValueKey('energy-reserve-entity'),
              controller: entityController,
              enabled: !controller.reserveSetupNeedsRefresh,
              placeholder: text.setupEntity,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onChanged: (_) => onEntityChanged(),
              onSubmitted: validEntity && !controller.reserveSetupNeedsRefresh
                  ? controller.acceptReserveSource
                  : null,
            ),
            const SizedBox(height: 10),
            CupertinoButton.filled(
              key: const ValueKey('energy-reserve-bind-source'),
              onPressed: validEntity && !controller.reserveSetupNeedsRefresh
                  ? () => controller.acceptReserveSource(entityController.text)
                  : null,
              child: Text(text.setupAccept),
            ),
          ],
          if (controller.reserveSetupFailure != null) ...[
            const SizedBox(height: 10),
            Text(text.setupFailed),
            const SizedBox(height: 6),
            CupertinoButton(
              key: const ValueKey('energy-reserve-setup-refresh'),
              onPressed: controller.load,
              child: Text(text.setupRefresh),
            ),
          ],
        ],
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller, required this.text});
  final EnergyPriorityController controller;
  final _Text text;
  @override
  Widget build(BuildContext context) {
    final value = switch (controller.state) {
      EnergyPriorityViewState.failed => text.failed,
      EnergyPriorityViewState.stale => text.stale,
      EnergyPriorityViewState.verified => text.verified,
      EnergyPriorityViewState.idle ||
      EnergyPriorityViewState.loading ||
      EnergyPriorityViewState.busy => text.loading,
      _ => text.advisory,
    };
    return Semantics(
      liveRegion: true,
      label: value,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(CupertinoIcons.sun_max),
              const SizedBox(width: 12),
              Expanded(child: Text(value)),
              if (controller.state == EnergyPriorityViewState.loading ||
                  controller.state == EnergyPriorityViewState.busy)
                const CupertinoActivityIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.snapshot, required this.text});
  final EnergyPrioritySnapshot snapshot;
  final _Text text;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900 ? 4 : 2;
      final width = (constraints.maxWidth - 24) / columns;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            children: [
              _Metric(
                width: width,
                label: text.solar,
                value: '${snapshot.solarEnergyWh} Wh',
              ),
              _Metric(
                width: width,
                label: text.load,
                value: '${snapshot.consumptionEnergyWh} Wh',
              ),
              _Metric(
                width: width,
                label: text.battery,
                value: '${snapshot.stateOfChargePercent}%',
              ),
              _Metric(
                key: const ValueKey('energy-reserve-percent'),
                width: width,
                label: text.reserve,
                value: '${snapshot.reservePercent}%',
              ),
            ],
          ),
          if (snapshot.meterCapturedAt != null &&
              snapshot.batteryCapturedAt != null &&
              snapshot.forecastGeneratedAt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                '${text.freshness}: '
                '${_clock(snapshot.meterCapturedAt!)} · '
                '${_clock(snapshot.batteryCapturedAt!)} · '
                '${_clock(snapshot.forecastGeneratedAt!)}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      );
    },
  );
}

String _clock(DateTime value) {
  final local = value.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.snapshot, required this.text});
  final EnergyPrioritySnapshot snapshot;
  final _Text text;

  String _action(EnergyPlanSlot slot) => switch (slot.action) {
    EnergyPlanAction.charge => text.charge,
    EnergyPlanAction.discharge => text.discharge,
    EnergyPlanAction.hold => text.hold,
  };

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          text.timeline,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        for (final slot in snapshot.slots.take(12))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    slot.startsAt == null
                        ? '#${slot.index + 1}'
                        : _clock(slot.startsAt!),
                  ),
                ),
                Icon(switch (slot.action) {
                  EnergyPlanAction.charge => CupertinoIcons.battery_25,
                  EnergyPlanAction.discharge => CupertinoIcons.bolt_fill,
                  EnergyPlanAction.hold => CupertinoIcons.pause_circle,
                }, size: 20),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: Text(_action(slot))),
                Expanded(
                  flex: 3,
                  child: Text(
                    '${slot.powerW} W · ${slot.projectedSocWh} Wh',
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    super.key,
    required this.width,
    required this.label,
    required this.value,
  });
  final double width;
  final String label, value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}
