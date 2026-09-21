import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/room_comfort_controller.dart';
import '../domain/room_comfort_models.dart';

final class RoomComfortStrings {
  const RoomComfortStrings({
    required this.title,
    required this.refresh,
    required this.loading,
    required this.unavailable,
    required this.stale,
    required this.invalidScope,
    required this.noPlan,
    required this.planned,
    required this.skipped,
    required this.blocked,
    required this.heat,
    required this.cool,
    required this.ventilate,
    required this.hvacOff,
    required this.windowOpen,
    required this.windowClosed,
    required this.advisoryOccupied,
    required this.advisoryUnoccupied,
    required this.advisoryStale,
    required this.review,
    required this.confirmTitle,
    required this.confirmBody,
    required this.confirm,
    required this.cancel,
    required this.recorded,
    required this.reasons,
  });

  final String title, refresh, loading, unavailable, stale, invalidScope;
  final String noPlan, planned, skipped, blocked, heat, cool, ventilate;
  final String hvacOff, windowOpen, windowClosed;
  final String advisoryOccupied, advisoryUnoccupied, advisoryStale;
  final String review, confirmTitle, confirmBody, confirm, cancel, recorded;
  final Map<ComfortReason, String> reasons;

  static const en = RoomComfortStrings(
    title: 'Room comfort',
    refresh: 'Refresh verified comfort plan',
    loading: 'Loading the verified comfort plan…',
    unavailable: 'The comfort plan is unavailable.',
    stale: 'This plan belongs to an earlier session. Refresh to continue.',
    invalidScope: 'The plan did not match this Core, home, or session.',
    noPlan: 'No verified comfort plan is available.',
    planned: 'Planned',
    skipped: 'Comfortable',
    blocked: 'Safety blocked',
    heat: 'Heat',
    cool: 'Cool',
    ventilate: 'Ventilate',
    hvacOff: 'HVAC off',
    windowOpen: 'Window open',
    windowClosed: 'Window closed',
    advisoryOccupied: 'Occupancy advisory: occupied',
    advisoryUnoccupied: 'Occupancy advisory: unoccupied',
    advisoryStale: 'Occupancy advisory: stale',
    review: 'Review comfort plan',
    confirmTitle: 'Confirm comfort plan',
    confirmBody: 'Larenor records this exact plan request. Device delivery remains unverified until provider readback.',
    confirm: 'Confirm plan',
    cancel: 'Not now',
    recorded: 'Plan request recorded. Device delivery is not verified.',
    reasons: {
      ComfortReason.airRefresh: 'Air refresh recommended',
      ComfortReason.temperatureLow: 'Temperature below target',
      ComfortReason.temperatureHigh: 'Temperature above target',
      ComfortReason.comfortable: 'Within the comfort range',
      ComfortReason.manualOverride: 'Time-limited manual override',
      ComfortReason.sensorStale: 'Sensor reading is stale',
      ComfortReason.smokeDetected: 'Smoke detected',
      ComfortReason.freezeRisk: 'Outdoor freeze risk',
      ComfortReason.rainWindowBlock: 'Rain prevents window ventilation',
      ComfortReason.outdoorAirUnsafe: 'Outdoor air quality is unsafe',
    },
  );

  static const tr = RoomComfortStrings(
    title: 'Oda konforu',
    refresh: 'Doğrulanmış konfor planını yenile',
    loading: 'Doğrulanmış konfor planı yükleniyor…',
    unavailable: 'Konfor planına ulaşılamıyor.',
    stale: 'Bu plan önceki oturuma ait. Devam etmek için yenileyin.',
    invalidScope: 'Plan bu Core, ev veya oturumla eşleşmedi.',
    noPlan: 'Doğrulanmış konfor planı yok.',
    planned: 'Planlandı',
    skipped: 'Konforlu',
    blocked: 'Güvenlik engelledi',
    heat: 'Isıt',
    cool: 'Soğut',
    ventilate: 'Havalandır',
    hvacOff: 'İklimlendirme kapalı',
    windowOpen: 'Pencere açık',
    windowClosed: 'Pencere kapalı',
    advisoryOccupied: 'Varlık önerisi: odada biri var',
    advisoryUnoccupied: 'Varlık önerisi: oda boş',
    advisoryStale: 'Varlık önerisi: güncel değil',
    review: 'Konfor planını incele',
    confirmTitle: 'Konfor planını onayla',
    confirmBody: 'Larenor bu tam plan isteğini kaydeder. Sağlayıcı geri okumasına kadar cihaza iletim doğrulanmış sayılmaz.',
    confirm: 'Planı onayla',
    cancel: 'Şimdi değil',
    recorded: 'Plan isteği kaydedildi. Cihaza iletim doğrulanmadı.',
    reasons: {
      ComfortReason.airRefresh: 'Hava yenileme öneriliyor',
      ComfortReason.temperatureLow: 'Sıcaklık hedefin altında',
      ComfortReason.temperatureHigh: 'Sıcaklık hedefin üstünde',
      ComfortReason.comfortable: 'Konfor aralığında',
      ComfortReason.manualOverride: 'Süreli elle geçersiz kılma',
      ComfortReason.sensorStale: 'Sensör ölçümü güncel değil',
      ComfortReason.smokeDetected: 'Duman algılandı',
      ComfortReason.freezeRisk: 'Dışarıda don riski',
      ComfortReason.rainWindowBlock:
          'Yağmur pencere havalandırmasını engelliyor',
      ComfortReason.outdoorAirUnsafe: 'Dış hava kalitesi güvenli değil',
    },
  );
}

class RoomComfortScreen extends StatefulWidget {
  const RoomComfortScreen({
    super.key,
    required this.controller,
    required this.strings,
  });

  final RoomComfortController controller;
  final RoomComfortStrings strings;

  @override
  State<RoomComfortScreen> createState() => _RoomComfortScreenState();
}

class _RoomComfortScreenState extends State<RoomComfortScreen>
    with WidgetsBindingObserver {
  bool _foreground = true;

  bool get _current =>
      mounted &&
      _foreground &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    unawaited(widget.controller.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _review() async {
    if (!_current) return;
    final preview = await widget.controller.preview();
    if (!mounted || !_current || preview == null) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(widget.strings.confirmTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(widget.strings.confirmBody),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(child: Text(widget.strings.cancel)),
            ),
          ),
          CupertinoDialogAction(
            key: const ValueKey('comfort-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(child: Text(widget.strings.confirm)),
            ),
          ),
        ],
      ),
    );
    if (!mounted || !_current) return;
    if (accepted == true) {
      await widget.controller.confirm(preview);
    } else {
      widget.controller.cancelPreview(preview);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) widget.controller.retire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
          child: _body(
            (constraints.maxWidth - 48).clamp(0, double.infinity).toDouble(),
          ),
        ),
      ),
    ),
  );

  Widget _body(double width) {
    final controller = widget.controller;
    if (controller.busy && controller.plan == null) {
      return _Status(text: widget.strings.loading);
    }
    final failure = controller.failure;
    if (failure != null && controller.plan == null) {
      return _Status(
        live: true,
        text: _failureText(failure),
        actionLabel: widget.strings.refresh,
        onAction: controller.busy || !_current ? null : controller.refresh,
      );
    }
    final plan = controller.plan;
    if (plan == null) {
      return _Status(
        text: widget.strings.noPlan,
        actionLabel: widget.strings.refresh,
        onAction: controller.busy || !_current ? null : controller.refresh,
      );
    }
    final columns = width >= 1000 ? 2 : 1;
    const gap = 20.0;
    final cardWidth = (width - gap * (columns - 1)) / columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failure != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_failureText(failure), style: AppText.body),
            ),
          ),
        if (controller.receipt != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(widget.strings.recorded, style: AppText.headline),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Semantics(
            button: true,
            label: widget.strings.refresh,
            child: CupertinoButton(
              key: const ValueKey('comfort-refresh'),
              autofocus: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(48, 48),
              onPressed: controller.busy || !_current
                  ? null
                  : controller.refresh,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.refresh),
                  const SizedBox(width: 8),
                  Flexible(child: Text(widget.strings.refresh)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: CupertinoButton.filled(
            key: const ValueKey('comfort-review'),
            minimumSize: const Size(48, 48),
            onPressed:
                controller.busy ||
                    !_current ||
                    plan.rooms.every(
                      (room) => room.status != ComfortPlanStatus.planned,
                    )
                ? null
                : _review,
            child: Text(widget.strings.review),
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final room in plan.rooms)
              SizedBox(
                width: cardWidth,
                child: _RoomCard(room: room, strings: widget.strings),
              ),
          ],
        ),
      ],
    );
  }

  String _failureText(RoomComfortFailure failure) => switch (failure) {
    RoomComfortFailure.unavailable => widget.strings.unavailable,
    RoomComfortFailure.staleAuthority => widget.strings.stale,
    RoomComfortFailure.invalidScope => widget.strings.invalidScope,
  };
}

class _Status extends StatelessWidget {
  const _Status({
    required this.text,
    this.live = false,
    this.actionLabel,
    this.onAction,
  });
  final String text;
  final bool live;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: live,
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: AppText.emptyStateBody,
            textAlign: TextAlign.center,
          ),
          if (actionLabel case final action?) ...[
            const SizedBox(height: 16),
            CupertinoButton(
              key: const ValueKey('comfort-status-refresh'),
              minimumSize: const Size(48, 48),
              onPressed: onAction,
              child: Text(action),
            ),
          ],
        ],
      ),
    ),
  );
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({required this.room, required this.strings});
  final RoomComfortPlanItem room;
  final RoomComfortStrings strings;

  @override
  Widget build(BuildContext context) {
    final status = switch (room.status) {
      ComfortPlanStatus.planned => strings.planned,
      ComfortPlanStatus.skipped => strings.skipped,
      ComfortPlanStatus.blocked => strings.blocked,
    };
    final hvac = switch (room.hvacMode) {
      ComfortHvacMode.off => strings.hvacOff,
      ComfortHvacMode.heat => strings.heat,
      ComfortHvacMode.cool => strings.cool,
      ComfortHvacMode.ventilate => strings.ventilate,
    };
    final occupancy = switch (room.occupancy) {
      ComfortOccupancy.occupied => strings.advisoryOccupied,
      ComfortOccupancy.unoccupied => strings.advisoryUnoccupied,
      ComfortOccupancy.stale => strings.advisoryStale,
    };
    return Semantics(
      container: true,
      label: '$status. ${strings.reasons[room.reason]}. $hvac.',
      child: DecoratedBox(
        key: ValueKey('comfort-room-${room.roomId[0]}'),
        decoration: BoxDecoration(
          color: AppColors.surface.resolveFrom(context),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(status, style: AppText.title2),
              const SizedBox(height: 12),
              Text(strings.reasons[room.reason]!, style: AppText.headline),
              const SizedBox(height: 10),
              Text(hvac, style: AppText.body),
              Text(
                room.windowState == ComfortWindowState.open
                    ? strings.windowOpen
                    : strings.windowClosed,
                style: AppText.body,
              ),
              const SizedBox(height: 10),
              Text(occupancy, style: AppText.caption1),
            ],
          ),
        ),
      ),
    );
  }
}
