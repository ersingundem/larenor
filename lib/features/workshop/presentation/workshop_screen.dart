import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/workshop_controller.dart';
import '../domain/workshop_models.dart';

final class WorkshopStrings {
  const WorkshopStrings({
    required this.title,
    required this.refresh,
    required this.loading,
    required this.empty,
    required this.unavailable,
    required this.stale,
    required this.actionUncertain,
    required this.safe,
    required this.offline,
    required this.staleReading,
    required this.thermalWarning,
    required this.thermalRunaway,
    required this.filamentLow,
    required this.filamentRunout,
    required this.doorOpen,
    required this.emergency,
    required this.progress,
    required this.material,
    required this.previewPause,
    required this.previewCancel,
    required this.confirmTitle,
    required this.confirmBody,
    required this.confirm,
    required this.dismiss,
    required this.intentRecorded,
  });

  final String title, refresh, loading, empty, unavailable, stale;
  final String actionUncertain, safe, offline, staleReading;
  final String thermalWarning, thermalRunaway, filamentLow, filamentRunout;
  final String doorOpen, emergency, progress, material;
  final String previewPause, previewCancel, confirmTitle, confirmBody;
  final String confirm, dismiss, intentRecorded;

  static const en = WorkshopStrings(
    title: 'Workshop',
    refresh: 'Refresh workshop status',
    loading: 'Loading verified printer status…',
    empty: 'No workshop printers are registered.',
    unavailable: 'Printer status is unavailable.',
    stale: 'This status belongs to an earlier session. Refresh to continue.',
    actionUncertain: 'The request result is uncertain. Check the printer before trying again.',
    safe: 'Safety checks verified',
    offline: 'Printer offline',
    staleReading: 'Safety reading is stale',
    thermalWarning: 'Temperature warning',
    thermalRunaway: 'Thermal runaway detected',
    filamentLow: 'Filament is low',
    filamentRunout: 'Filament has run out',
    doorOpen: 'Printer door is open',
    emergency: 'Emergency stop is active',
    progress: 'Progress',
    material: 'Material remaining',
    previewPause: 'Review pause request',
    previewCancel: 'Review cancel request',
    confirmTitle: 'Confirm printer request',
    confirmBody: 'Larenor records this bounded request for the current verified printer state. It does not retry an uncertain request.',
    confirm: 'Confirm request',
    dismiss: 'Not now',
    intentRecorded: 'Request recorded. Delivery has not been claimed.',
  );

  static const tr = WorkshopStrings(
    title: 'Atölye',
    refresh: 'Atölye durumunu yenile',
    loading: 'Doğrulanmış yazıcı durumu yükleniyor…',
    empty: 'Kayıtlı atölye yazıcısı yok.',
    unavailable: 'Yazıcı durumuna ulaşılamıyor.',
    stale: 'Bu durum önceki oturuma ait. Devam etmek için yenileyin.',
    actionUncertain: 'İsteğin sonucu belirsiz. Yeniden denemeden önce yazıcıyı kontrol edin.',
    safe: 'Güvenlik kontrolleri doğrulandı',
    offline: 'Yazıcı çevrimdışı',
    staleReading: 'Güvenlik ölçümü güncel değil',
    thermalWarning: 'Sıcaklık uyarısı',
    thermalRunaway: 'Kontrolsüz sıcaklık artışı algılandı',
    filamentLow: 'Filament azalıyor',
    filamentRunout: 'Filament tükendi',
    doorOpen: 'Yazıcı kapağı açık',
    emergency: 'Acil durdurma etkin',
    progress: 'İlerleme',
    material: 'Kalan malzeme',
    previewPause: 'Duraklatma isteğini incele',
    previewCancel: 'İptal isteğini incele',
    confirmTitle: 'Yazıcı isteğini onayla',
    confirmBody: 'Larenor bu sınırlı isteği doğrulanmış güncel yazıcı durumu için kaydeder. Sonucu belirsiz bir isteği otomatik tekrarlamaz.',
    confirm: 'İsteği onayla',
    dismiss: 'Şimdi değil',
    intentRecorded: 'İstek kaydedildi. İletildiği iddia edilmedi.',
  );
}

class WorkshopScreen extends StatefulWidget {
  const WorkshopScreen({
    super.key,
    required this.controller,
    required this.strings,
  });

  final WorkshopController controller;
  final WorkshopStrings strings;

  @override
  State<WorkshopScreen> createState() => _WorkshopScreenState();
}

class _WorkshopScreenState extends State<WorkshopScreen>
    with WidgetsBindingObserver {
  bool _foreground = true;

  bool get _routeCurrent =>
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

  Future<void> _request(WorkshopPrinter printer, WorkshopAction action) async {
    if (!_routeCurrent) return;
    final preview = await widget.controller.requestAction(printer, action);
    if (!mounted || !_routeCurrent || preview == null) return;
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
              child: Center(child: Text(widget.strings.dismiss)),
            ),
          ),
          CupertinoDialogAction(
            key: const ValueKey('workshop-confirm'),
            isDestructiveAction: action == WorkshopAction.cancel,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(child: Text(widget.strings.confirm)),
            ),
          ),
        ],
      ),
    );
    if (!mounted || !_routeCurrent) return;
    if (accepted == true) {
      await widget.controller.confirm(preview);
    } else {
      widget.controller.cancelPreview(preview);
    }
  }

  String _failure(WorkshopFailure failure) => switch (failure) {
    WorkshopFailure.staleAuthority => widget.strings.stale,
    WorkshopFailure.actionUncertain => widget.strings.actionUncertain,
    WorkshopFailure.unavailable ||
    WorkshopFailure.invalidResponse => widget.strings.unavailable,
  };

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.strings.title),
        trailing: Semantics(
          button: true,
          label: widget.strings.refresh,
          child: CupertinoButton(
            padding: const EdgeInsets.all(12),
            minimumSize: const Size(48, 48),
            onPressed: controller.busy || !_routeCurrent
                ? null
                : controller.refresh,
            child: const Icon(CupertinoIcons.refresh),
          ),
        ),
      ),
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
  }

  Widget _body(double width) {
    final controller = widget.controller;
    if (controller.busy && !controller.loaded) {
      return _Status(
        icon: CupertinoIcons.hourglass,
        text: widget.strings.loading,
      );
    }
    if (controller.failure case final failure?) {
      return _Status(
        icon: CupertinoIcons.exclamationmark_triangle,
        text: _failure(failure),
        live: true,
      );
    }
    if (controller.loaded && controller.printers.isEmpty) {
      return _Status(icon: CupertinoIcons.cube_box, text: widget.strings.empty);
    }
    final columns = width >= 1000 ? 2 : 1;
    final gap = 20.0;
    final cardWidth = (width - gap * (columns - 1)) / columns;
    final firstActionable = controller.printers
        .where((printer) => printer.availableActions.isNotEmpty)
        .map((printer) => printer.id)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.lastReceipt != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                widget.strings.intentRecorded,
                style: AppText.headline,
              ),
            ),
          ),
        Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final printer in controller.printers)
              SizedBox(
                width: cardWidth,
                child: _PrinterCard(
                  key: ValueKey('workshop-${printer.id[0]}'),
                  printer: printer,
                  strings: widget.strings,
                  busy: controller.busy,
                  autofocus: printer.id == firstActionable,
                  onAction: (action) => _request(printer, action),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.icon, required this.text, this.live = false});
  final IconData icon;
  final String text;
  final bool live;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: live,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Icon(icon, size: 36),
            const SizedBox(height: 16),
            Text(
              text,
              style: AppText.emptyStateBody,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    super.key,
    required this.printer,
    required this.strings,
    required this.busy,
    required this.autofocus,
    required this.onAction,
  });
  final WorkshopPrinter printer;
  final WorkshopStrings strings;
  final bool busy, autofocus;
  final ValueChanged<WorkshopAction> onAction;

  List<String> get warnings {
    final safety = printer.safety;
    return [
      if (safety.connectivity == WorkshopConnectivity.offline) strings.offline,
      if (safety.freshness == WorkshopFreshness.stale) strings.staleReading,
      if (safety.thermal == WorkshopThermal.warning) strings.thermalWarning,
      if (safety.thermal == WorkshopThermal.runaway) strings.thermalRunaway,
      if (safety.filament == WorkshopFilament.low) strings.filamentLow,
      if (safety.filament == WorkshopFilament.runout) strings.filamentRunout,
      if (safety.door == WorkshopDoor.open) strings.doorOpen,
      if (safety.emergency == WorkshopEmergency.triggered) strings.emergency,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final alerts = warnings;
    return DecoratedBox(
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
            Text(printer.name, style: AppText.title2),
            const SizedBox(height: 12),
            _Detail(
              icon: CupertinoIcons.chart_bar,
              text:
                  '${strings.progress}: ${(printer.job.progressPermille / 10).toStringAsFixed(0)}%',
            ),
            _Detail(
              icon: CupertinoIcons.cube_box,
              text:
                  '${strings.material}: ${printer.material.remainingGrams.toStringAsFixed(0)} g',
            ),
            const SizedBox(height: 12),
            if (alerts.isEmpty)
              _Detail(
                icon: CupertinoIcons.check_mark_circled,
                text: strings.safe,
              )
            else
              for (final warning in alerts)
                _Detail(
                  icon: CupertinoIcons.exclamationmark_triangle,
                  text: warning,
                  warning: true,
                ),
            if (printer.availableActions.isNotEmpty) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (printer.availableActions.contains(WorkshopAction.pause))
                    _ActionButton(
                      key: ValueKey('workshop-pause-${printer.id[0]}'),
                      label: strings.previewPause,
                      autofocus: autofocus,
                      enabled: !busy,
                      onPressed: () => onAction(WorkshopAction.pause),
                    ),
                  if (printer.availableActions.contains(WorkshopAction.cancel))
                    _ActionButton(
                      key: ValueKey('workshop-cancel-${printer.id[0]}'),
                      label: strings.previewCancel,
                      destructive: true,
                      enabled: !busy,
                      onPressed: () => onAction(WorkshopAction.cancel),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.icon, required this.text, this.warning = false});
  final IconData icon;
  final String text;
  final bool warning;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 22,
          color: warning ? CupertinoColors.systemOrange : CupertinoColors.label,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppText.body)),
      ],
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.autofocus = false,
    this.destructive = false,
  });
  final String label;
  final bool enabled, autofocus, destructive;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: CupertinoButton(
      autofocus: autofocus,
      minimumSize: const Size(48, 48),
      color: destructive
          ? CupertinoColors.systemRed
          : CupertinoColors.activeBlue,
      onPressed: enabled ? onPressed : null,
      child: Text(label),
    ),
  );
}
