import 'package:flutter/cupertino.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/energy_priority_controller.dart';
import '../domain/energy_priority_models.dart';

final class _Text {
  const _Text(this.tr);
  factory _Text.of(BuildContext context) =>
      _Text(Localizations.localeOf(context).languageCode == 'tr');
  final bool tr;
  String get title => tr ? 'Güneş ve batarya' : 'Solar and battery';
  String get advisory => tr
      ? 'Bu plan öneridir; otomatik inverter yazması yapmaz.'
      : 'This plan is advisory and never writes to the inverter automatically.';
  String get unavailable => tr
      ? 'Gerçek inverter yazması bu cihazda doğrulanmadı.'
      : 'Physical inverter writes are not verified on this device.';
  String get solar => tr ? 'Güneş üretimi' : 'Solar production';
  String get load => tr ? 'Tüketim' : 'Consumption';
  String get battery => tr ? 'Batarya' : 'Battery';
  String get reserve => tr ? 'Yedek rezerv' : 'Backup reserve';
  String get preview => tr ? 'İlk eylemi önizle' : 'Preview first action';
  String get confirm =>
      tr ? 'İnverter eylemini onayla' : 'Confirm inverter action';
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get refresh => tr ? 'Yenile' : 'Refresh';
  String get loading => tr ? 'Enerji planı yükleniyor' : 'Loading energy plan';
  String get failed => tr
      ? 'Core enerji planı doğrulanamadı'
      : 'Core energy plan could not be verified';
  String get stale => tr
      ? 'Hesap, oturum veya rota değişti'
      : 'Account, session, or route changed';
  String get verified =>
      tr ? 'İnverter okuması doğrulandı' : 'Inverter readback verified';
  String get timeline => tr ? 'Bugünün enerji planı' : 'Today’s energy plan';
  String get freshness => tr ? 'Veri güncelliği' : 'Data freshness';
  String get charge => tr ? 'Şarj et' : 'Charge';
  String get discharge => tr ? 'Bataryadan kullan' : 'Use battery';
  String get hold => tr ? 'Beklet' : 'Hold';
  String get noCurrentAction => tr
      ? 'Şu an uygulanabilir bir inverter eylemi yok.'
      : 'There is no inverter action to apply right now.';
}

class EnergyPriorityScreen extends StatefulWidget {
  const EnergyPriorityScreen({super.key, required this.controller});
  final EnergyPriorityController controller;
  @override
  State<EnergyPriorityScreen> createState() => _EnergyPriorityScreenState();
}

class _EnergyPriorityScreenState extends State<EnergyPriorityScreen> {
  AppInteractionController? _interaction;
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
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _interaction?.removeListener(_interactionChanged);
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
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
              if (snapshot != null) _Timeline(snapshot: snapshot, text: text),
              if (snapshot != null && !snapshot.canControl)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(text.unavailable),
                ),
              if (snapshot != null &&
                  currentAction != null &&
                  snapshot.canControl &&
                  controller.pending == null)
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
                  currentAction == null &&
                  controller.pending == null)
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
                SettingsActionTile(
                  buttonKey: const ValueKey('energy-cancel-preview'),
                  leading: const Icon(CupertinoIcons.clear_circled),
                  title: Text(text.cancel),
                  onTap: controller.canAct ? controller.cancelPreview : null,
                ),
              ],
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
