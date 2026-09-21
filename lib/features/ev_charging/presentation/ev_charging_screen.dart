import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/ev_charging_controller.dart';
import '../domain/ev_charging_models.dart';

final class EvChargingStrings {
  const EvChargingStrings({
    required this.title,
    required this.refresh,
    required this.unavailable,
    required this.providerMissing,
    required this.target,
    required this.departure,
    required this.hours,
    required this.preview,
    required this.confirm,
    required this.uncertain,
    required this.ready,
    required this.current,
    required this.required,
    required this.noChargers,
  });
  final String title,
      refresh,
      unavailable,
      providerMissing,
      target,
      departure,
      hours;
  final String preview,
      confirm,
      uncertain,
      ready,
      current,
      required,
      noChargers;
  static const en = EvChargingStrings(
    title: 'EV charging',
    refresh: 'Refresh charger status',
    unavailable: 'Charging status is unavailable.',
    providerMissing: 'No verified OCPP or vehicle provider is connected. Planning and control stay disabled.',
    target: 'Target battery',
    departure: 'Departure in',
    hours: 'hours',
    preview: 'Preview safe plan',
    confirm: 'Confirm charge plan',
    uncertain: 'Command recorded; charger result is not verified yet.',
    ready: 'Verified provider',
    current: 'Current battery',
    required: 'Planned energy',
    noChargers: 'No supported charger is available.',
  );
  static const tr = EvChargingStrings(
    title: 'Elektrikli araç şarjı',
    refresh: 'Şarj durumunu yenile',
    unavailable: 'Şarj durumuna ulaşılamıyor.',
    providerMissing: 'Doğrulanmış OCPP veya araç sağlayıcısı bağlı değil. Planlama ve kontrol kapalı kalır.',
    target: 'Hedef batarya',
    departure: 'Ayrılışa',
    hours: 'saat',
    preview: 'Güvenli planı önizle',
    confirm: 'Şarj planını onayla',
    uncertain: 'Komut kaydedildi; şarj cihazı sonucu henüz doğrulanmadı.',
    ready: 'Doğrulanmış sağlayıcı',
    current: 'Mevcut batarya',
    required: 'Planlanan enerji',
    noChargers: 'Desteklenen şarj cihazı yok.',
  );
}

class EvChargingScreen extends StatefulWidget {
  const EvChargingScreen({
    super.key,
    required this.controller,
    required this.strings,
  });
  final EvChargingController controller;
  final EvChargingStrings strings;
  @override
  State<EvChargingScreen> createState() => _EvChargingScreenState();
}

class _EvChargingScreenState extends State<EvChargingScreen> {
  int _target = 80, _hours = 8;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
          child: _body(constraints.maxWidth - 48),
        ),
      ),
    ),
  );

  Widget _body(double width) {
    final controller = widget.controller, strings = widget.strings;
    if (controller.busy && controller.capabilityValue == null) {
      return _message(strings.unavailable);
    }
    if (controller.failure != null && controller.capabilityValue == null) {
      return _message(strings.unavailable, live: true);
    }
    final capability = controller.capabilityValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: CupertinoButton(
            key: const ValueKey('ev-charge-refresh'),
            minimumSize: const Size(48, 48),
            autofocus: true,
            onPressed: controller.busy ? null : controller.refresh,
            child: Text(strings.refresh),
          ),
        ),
        if (capability == null || capability.state != EvCapabilityState.ready)
          _message(strings.providerMissing)
        else if (capability.chargers.isEmpty)
          _message(strings.noChargers)
        else
          _charger(capability.chargers.first, width),
      ],
    );
  }

  Widget _charger(EvChargerCapability charger, double width) {
    if (_target <= charger.currentSoc) {
      _target = (charger.currentSoc + 10).clamp(1, 100);
    }
    final cards = <Widget>[
      _card(
        key: const ValueKey('ev-charge-goal'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(charger.label, style: AppText.title2),
            Text(
              '${widget.strings.current}: ${charger.currentSoc}%',
              style: AppText.body,
            ),
            const SizedBox(height: 16),
            Semantics(
              label: '${widget.strings.target}: $_target%',
              value: '$_target%',
              child: CupertinoSlider(
                value: _target.toDouble(),
                min: charger.currentSoc == 100
                    ? 0
                    : charger.currentSoc.toDouble(),
                max: 100,
                divisions: charger.currentSoc == 100
                    ? 100
                    : 100 - charger.currentSoc,
                onChanged: widget.controller.busy || charger.currentSoc == 100
                    ? null
                    : (value) {
                        widget.controller.discardPlan();
                        setState(() => _target = value.round());
                      },
              ),
            ),
            Text(
              '${widget.strings.target}: $_target%',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            CupertinoSlidingSegmentedControl<int>(
              groupValue: _hours,
              children: {
                for (final value in [2, 4, 8, 12])
                  value: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text('$value ${widget.strings.hours}'),
                  ),
              },
              onValueChanged: (value) {
                if (!widget.controller.busy && value != null) {
                  widget.controller.discardPlan();
                  setState(() => _hours = value);
                }
              },
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              key: const ValueKey('ev-charge-preview'),
              minimumSize: const Size(48, 48),
              onPressed: widget.controller.busy || charger.currentSoc == 100
                  ? null
                  : () => widget.controller.preview(charger, _target, _hours),
              child: Text(widget.strings.preview),
            ),
          ],
        ),
      ),
      if (widget.controller.plan case final plan?)
        _card(
          key: const ValueKey('ev-charge-plan'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.strings.ready, style: AppText.title2),
              Text(
                '${widget.strings.required}: ${(plan.requiredWh / 1000).toStringAsFixed(1)} kWh',
              ),
              Text(
                '${widget.strings.departure}: $_hours ${widget.strings.hours}',
              ),
              const SizedBox(height: 16),
              if (plan.status == 'ready')
                CupertinoButton.filled(
                  key: const ValueKey('ev-charge-confirm'),
                  minimumSize: const Size(48, 48),
                  autofocus: true,
                  onPressed: widget.controller.busy
                      ? null
                      : widget.controller.confirm,
                  child: Text(widget.strings.confirm),
                ),
            ],
          ),
        ),
      if (widget.controller.receipt case final receipt?)
        _message(
          receipt.status == 'verified'
              ? widget.strings.ready
              : widget.strings.uncertain,
          live: true,
        ),
    ];
    if (width >= 1000 && cards.length >= 2) {
      return Wrap(
        spacing: 20,
        runSpacing: 20,
        children: [
          for (final card in cards)
            SizedBox(width: (width - 20) / 2, child: card),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < cards.length; index++) ...[
          if (index > 0) const SizedBox(height: 20),
          cards[index],
        ],
      ],
    );
  }

  Widget _card({required Key key, required Widget child}) => DecoratedBox(
    key: key,
    decoration: BoxDecoration(
      color: AppColors.surface.resolveFrom(context),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: CupertinoColors.separator.resolveFrom(context)),
    ),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
  Widget _message(String value, {bool live = false}) => Semantics(
    liveRegion: live,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        value,
        style: AppText.emptyStateBody,
        textAlign: TextAlign.center,
      ),
    ),
  );
}
