import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/resource_reservation_controller.dart';
import '../domain/resource_reservation_models.dart';

class ResourceReservationStrings {
  const ResourceReservationStrings({
    required this.title,
    required this.availability,
    required this.newReservation,
    required this.localStart,
    required this.durationMinutes,
    required this.recurrenceCount,
    required this.timezone,
    required this.earlierFold,
    required this.laterFold,
    required this.once,
    required this.daily,
    required this.weekly,
    required this.create,
    required this.cancel,
    required this.history,
    required this.export,
    required this.exportReady,
    required this.loading,
    required this.empty,
    required this.offline,
    required this.error,
    required this.conflict,
    required this.uncertain,
    required this.reconcile,
    required this.created,
    required this.cancelled,
    required this.units,
  });

  factory ResourceReservationStrings.fromLocalizations(AppLocalizations l10n) =>
      ResourceReservationStrings(
        title: l10n.resourceReservationsTitle,
        availability: l10n.resourceReservationsAvailability,
        newReservation: l10n.resourceReservationsNew,
        localStart: l10n.resourceReservationsLocalStart,
        durationMinutes: l10n.resourceReservationsDurationMinutes,
        recurrenceCount: l10n.resourceReservationsRecurrenceCount,
        timezone: l10n.resourceReservationsTimezone,
        earlierFold: l10n.resourceReservationsEarlierFold,
        laterFold: l10n.resourceReservationsLaterFold,
        once: l10n.resourceReservationsOnce,
        daily: l10n.resourceReservationsDaily,
        weekly: l10n.resourceReservationsWeekly,
        create: l10n.resourceReservationsCreate,
        cancel: l10n.resourceReservationsCancel,
        history: l10n.resourceReservationsHistory,
        export: l10n.resourceReservationsExport,
        exportReady: l10n.resourceReservationsExportReady,
        loading: l10n.resourceReservationsLoading,
        empty: l10n.resourceReservationsEmpty,
        offline: l10n.resourceReservationsOffline,
        error: l10n.resourceReservationsError,
        conflict: l10n.resourceReservationsConflict,
        uncertain: l10n.resourceReservationsUncertain,
        reconcile: l10n.resourceReservationsReconcile,
        created: l10n.resourceReservationsCreated,
        cancelled: l10n.resourceReservationsCancelled,
        units: l10n.resourceReservationsUnits,
      );

  static const en = ResourceReservationStrings(
    title: 'Shared resources',
    availability: 'Availability',
    newReservation: 'New reservation',
    localStart: 'Local start (YYYY-MM-DDTHH:MM:SS)',
    durationMinutes: 'Duration in minutes',
    recurrenceCount: 'Occurrence count',
    timezone: 'Resource time zone',
    earlierFold: 'Earlier DST time',
    laterFold: 'Later DST time',
    once: 'Once',
    daily: 'Daily',
    weekly: 'Weekly',
    create: 'Create reservation',
    cancel: 'Cancel reservation',
    history: 'Reservation history',
    export: 'Read reservation export',
    exportReady: 'Bounded export is ready',
    loading: 'Loading current resource calendar',
    empty: 'No reservations in this calendar',
    offline: 'Core is not reachable',
    error: 'Current resource calendar could not be verified',
    conflict: 'This time conflicts with the current resource calendar',
    uncertain: 'The result is uncertain. Read its receipt before retrying.',
    reconcile: 'Check command result',
    created: 'Created',
    cancelled: 'Cancelled',
    units: 'units',
  );

  static const tr = ResourceReservationStrings(
    title: 'Ortak kaynaklar',
    availability: 'Müsaitlik',
    newReservation: 'Yeni rezervasyon',
    localStart: 'Yerel başlangıç (YYYY-AA-GGTHH:DD:SS)',
    durationMinutes: 'Dakika cinsinden süre',
    recurrenceCount: 'Tekrar sayısı',
    timezone: 'Kaynağın saat dilimi',
    earlierFold: 'Erken yaz saati karşılığı',
    laterFold: 'Geç yaz saati karşılığı',
    once: 'Bir kez',
    daily: 'Günlük',
    weekly: 'Haftalık',
    create: 'Rezervasyon oluştur',
    cancel: 'Rezervasyonu iptal et',
    history: 'Rezervasyon geçmişi',
    export: 'Rezervasyon dışa aktarımını oku',
    exportReady: 'Sınırlı dışa aktarım hazır',
    loading: 'Güncel kaynak takvimi yükleniyor',
    empty: 'Bu takvimde rezervasyon yok',
    offline: 'Core erişilebilir değil',
    error: 'Güncel kaynak takvimi doğrulanamadı',
    conflict: 'Bu zaman güncel kaynak takvimiyle çakışıyor',
    uncertain: 'Sonuç belirsiz. Yeniden denemeden önce makbuzu okuyun.',
    reconcile: 'Komut sonucunu denetle',
    created: 'Oluşturuldu',
    cancelled: 'İptal edildi',
    units: 'birim',
  );

  final String title;
  final String availability;
  final String newReservation;
  final String localStart;
  final String durationMinutes;
  final String recurrenceCount;
  final String timezone;
  final String earlierFold;
  final String laterFold;
  final String once;
  final String daily;
  final String weekly;
  final String create;
  final String cancel;
  final String history;
  final String export;
  final String exportReady;
  final String loading;
  final String empty;
  final String offline;
  final String error;
  final String conflict;
  final String uncertain;
  final String reconcile;
  final String created;
  final String cancelled;
  final String units;
}

class ResourceReservationScreen extends StatefulWidget {
  const ResourceReservationScreen({
    super.key,
    required this.controller,
    required this.authority,
    required this.strings,
  });

  final ResourceReservationController controller;
  final ResourceReservationAuthority authority;
  final ResourceReservationStrings strings;

  @override
  State<ResourceReservationScreen> createState() =>
      _ResourceReservationScreenState();
}

class _ResourceReservationScreenState extends State<ResourceReservationScreen> {
  final _localStart = TextEditingController();
  final _duration = TextEditingController(text: '60');
  final _count = TextEditingController(text: '1');
  late ReservationLease _lease;
  int _fold = 0;
  int _units = 1;
  String _frequency = 'none';

  @override
  void initState() {
    super.initState();
    for (final controller in [_localStart, _duration, _count]) {
      controller.addListener(_changed);
    }
    _attach();
  }

  void _attach() {
    _lease = widget.controller.bind(widget.authority);
    widget.controller.addListener(_controllerChanged);
    widget.controller.load(_lease);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _controllerChanged() {
    if (!mounted) return;
    final capacity = widget.controller.resource?.capacity ?? 1;
    if (_units > capacity) _units = capacity;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ResourceReservationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.authority != widget.authority) {
      oldWidget.controller.removeListener(_controllerChanged);
      oldWidget.controller.detach(_lease);
      _localStart.clear();
      _duration.text = '60';
      _count.text = '1';
      _fold = 0;
      _units = 1;
      _frequency = 'none';
      _attach();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    widget.controller.detach(_lease);
    for (final controller in [_localStart, _duration, _count]) {
      controller.removeListener(_changed);
      controller.dispose();
    }
    super.dispose();
  }

  ReservationDraft? get _draft {
    final resource = widget.controller.resource;
    if (resource == null) return null;
    return ReservationDraft.tryCreate(
      timezone: resource.timezone,
      localStart: _localStart.text.trim(),
      fold: _fold,
      durationMinutes: int.tryParse(_duration.text.trim()) ?? 0,
      units: _units,
      frequency: _frequency,
      recurrenceCount: int.tryParse(_count.text.trim()) ?? 0,
      capacity: resource.capacity,
    );
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final width = wide
              ? (constraints.maxWidth - 80) / 2
              : constraints.maxWidth - 32;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 32 : 16,
              vertical: 24,
            ),
            child: Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(width: width, child: _editor()),
                SizedBox(width: width, child: _calendar()),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _editor() {
    final strings = widget.strings;
    final resource = widget.controller.resource;
    final canCreate =
        widget.controller.canCreate &&
        (widget.controller.state == ReservationViewState.ready ||
            widget.controller.state == ReservationViewState.empty ||
            widget.controller.state == ReservationViewState.conflict);
    return _Panel(
      title: strings.newReservation,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (resource != null) ...[
            Text(
              resource.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Semantics(
              label: '${strings.timezone}: ${resource.timezone}',
              child: Text('${strings.timezone}: ${resource.timezone}'),
            ),
            const SizedBox(height: 12),
          ],
          CupertinoTextField(
            key: const ValueKey('reservation-local-start'),
            controller: _localStart,
            placeholder: strings.localStart,
            padding: const EdgeInsets.all(14),
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('reservation-duration'),
            controller: _duration,
            placeholder: strings.durationMinutes,
            keyboardType: TextInputType.number,
            padding: const EdgeInsets.all(14),
          ),
          const SizedBox(height: 12),
          CupertinoSlidingSegmentedControl<int>(
            groupValue: _fold,
            children: {
              0: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(strings.earlierFold),
              ),
              1: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(strings.laterFold),
              ),
            },
            onValueChanged: (value) => setState(() => _fold = value ?? _fold),
          ),
          const SizedBox(height: 12),
          CupertinoSlidingSegmentedControl<String>(
            groupValue: _frequency,
            children: {
              'none': Text(strings.once),
              'daily': Text(strings.daily),
              'weekly': Text(strings.weekly),
            },
            onValueChanged: (value) {
              setState(() {
                _frequency = value ?? _frequency;
                if (_frequency == 'none') _count.text = '1';
              });
            },
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('reservation-count'),
            controller: _count,
            placeholder: strings.recurrenceCount,
            keyboardType: TextInputType.number,
            padding: const EdgeInsets.all(14),
            enabled: _frequency != 'none',
          ),
          if (resource != null && resource.capacity > 1) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var unit = 1; unit <= resource.capacity; unit++)
                  _AccessibleButton(
                    label: '$unit ${strings.units}',
                    filled: _units == unit,
                    onPressed: () => setState(() => _units = unit),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _AccessibleButton(
            key: const ValueKey('reservation-create'),
            label: strings.create,
            filled: true,
            onPressed: _draft == null || !canCreate
                ? null
                : () => widget.controller.create(_lease, _draft!),
          ),
        ],
      ),
    );
  }

  Widget _calendar() {
    final strings = widget.strings;
    final state = widget.controller.state;
    final status = switch (state) {
      ReservationViewState.detached ||
      ReservationViewState.idle ||
      ReservationViewState.loading => strings.loading,
      ReservationViewState.empty => strings.empty,
      ReservationViewState.offline => strings.offline,
      ReservationViewState.error => strings.error,
      ReservationViewState.conflict => strings.conflict,
      ReservationViewState.uncertain => strings.uncertain,
      _ => null,
    };
    return _Panel(
      title: strings.availability,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status != null) Semantics(liveRegion: true, child: Text(status)),
          for (final item in widget.controller.busy)
            Text(
              '${item.startUtc} – ${item.endUtc} · ${item.units} ${strings.units}',
            ),
          if (widget.controller.reservations.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              strings.history,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          for (final item in widget.controller.reservations) ...[
            const SizedBox(height: 12),
            Text(
              item.localStart,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(item.fold == 0 ? strings.earlierFold : strings.laterFold),
            if (item.occurrences.isNotEmpty)
              Text(
                '${item.occurrences.first.startUtc} – ${item.occurrences.first.endUtc}',
              ),
            if (item.cancelled)
              Text(strings.cancelled)
            else if (item.canCancel)
              _AccessibleButton(
                key: ValueKey('reservation-cancel-${item.id}'),
                label: strings.cancel,
                onPressed: () => widget.controller.cancel(_lease, item),
              ),
          ],
          for (final event in widget.controller.history)
            Text(
              '${event.action == ReservationAction.create ? strings.created : strings.cancelled}'
              ' · ${event.actorId} · ${event.calendarRevision}',
            ),
          if (state == ReservationViewState.uncertain) ...[
            const SizedBox(height: 12),
            _AccessibleButton(
              label: strings.reconcile,
              filled: true,
              onPressed: () => widget.controller.reconcile(_lease),
            ),
          ],
          const SizedBox(height: 12),
          _AccessibleButton(
            key: const ValueKey('reservation-export'),
            label: strings.export,
            onPressed:
                state == ReservationViewState.ready ||
                    state == ReservationViewState.empty ||
                    state == ReservationViewState.conflict
                ? () => widget.controller.readExport(_lease)
                : null,
          ),
          if (widget.controller.exported.isNotEmpty)
            Semantics(
              liveRegion: true,
              label: strings.exportReady,
              child: Text(strings.exportReady),
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class _AccessibleButton extends StatelessWidget {
  const _AccessibleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    onTap: onPressed,
    excludeSemantics: true,
    child: FocusableActionDetector(
      enabled: onPressed != null,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed?.call();
            return null;
          },
        ),
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: filled
            ? CupertinoButton.filled(onPressed: onPressed, child: Text(label))
            : CupertinoButton(onPressed: onPressed, child: Text(label)),
      ),
    ),
  );
}
