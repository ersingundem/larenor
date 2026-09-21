import 'package:flutter/cupertino.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/sound_event_controller.dart';
import '../domain/sound_event_models.dart';

final class _Strings {
  const _Strings(this.tr);
  factory _Strings.of(BuildContext context) =>
      _Strings(Localizations.localeOf(context).languageCode == 'tr');
  final bool tr;
  String get title => tr ? 'Ses olayları' : 'Sound events';
  String get privacy => tr
      ? 'Yalnız sınıflandırma bilgisi ve kanıt özeti saklanır; ham ses saklanmaz.'
      : 'Only classification metadata and an evidence digest are retained; raw audio is not stored.';
  String get loading => tr ? 'Olaylar yükleniyor' : 'Loading events';
  String get empty =>
      tr ? 'Bu filtrede olay yok' : 'No events match these filters';
  String get failed =>
      tr ? 'Core sonucu doğrulanamadı' : 'Core result could not be verified';
  String get stale => tr
      ? 'Hesap, oturum veya rota değişti'
      : 'Account, session, or route changed';
  String get verified =>
      tr ? 'Okundu bilgisi doğrulandı' : 'Acknowledgement verified';
  String get refresh => tr ? 'Yenile' : 'Refresh';
  String get acknowledge => tr ? 'Okundu olarak işaretle' : 'Mark as reviewed';
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get confirm => tr ? 'Onayla' : 'Confirm';
  String get all => tr ? 'Tümü' : 'All';
  String get bark => tr ? 'Havlama' : 'Bark';
  String get noise => tr ? 'Diğer ses' : 'Other noise';
  String get unread => tr ? 'Yeni' : 'New';
  String get reviewed => tr ? 'İncelendi' : 'Reviewed';
}

class SoundEventScreen extends StatefulWidget {
  const SoundEventScreen({super.key, required this.controller});
  final SoundEventController controller;
  @override
  State<SoundEventScreen> createState() => _SoundEventScreenState();
}

class _SoundEventScreenState extends State<SoundEventScreen> {
  AppInteractionController? _interaction;
  int _viewEpoch = 0;

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

  void _interactionChanged() {
    final active = _interaction?.active ?? true;
    if (!active) _viewEpoch++;
    widget.controller.setInteractive(active);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _viewEpoch++;
    _interaction?.removeListener(_interactionChanged);
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    super.dispose();
  }

  Future<void> _confirm(SoundEventItem event) async {
    final epoch = _viewEpoch;
    final strings = _Strings.of(context);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(strings.acknowledge),
        content: Text(strings.privacy),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('sound-event-confirm-acknowledge'),
            isDefaultAction: true,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (mounted && epoch == _viewEpoch) {
                widget.controller.acknowledge(event);
              }
            },
            child: Text(strings.confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = _Strings.of(context);
    final controller = widget.controller;
    final events = controller.visibleEvents;
    return ServiceRootScaffold(
      title: strings.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(strings.privacy),
            children: [
              _LiveStatus(controller: controller, strings: strings),
              _Filters(controller: controller, strings: strings),
              if (controller.state == SoundEventViewState.failed ||
                  controller.state == SoundEventViewState.stale)
                SettingsActionTile(
                  buttonKey: const ValueKey('sound-event-retry'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(strings.refresh),
                  onTap: controller.canAct ? controller.load : null,
                ),
            ],
          ),
        ),
        if (events.isNotEmpty)
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900 ? 2 : 1;
                final width =
                    (constraints.maxWidth - 16 * (columns + 1)) / columns;
                return Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  children: [
                    for (final event in events)
                      SizedBox(
                        width: width,
                        child: _EventCard(
                          event: event,
                          strings: strings,
                          enabled: controller.canAct && !event.acknowledged,
                          onAcknowledge: () => _confirm(event),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.controller, required this.strings});
  final SoundEventController controller;
  final _Strings strings;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('sound-event-class-filter'),
          height: 48,
          child: CupertinoSlidingSegmentedControl<SoundEventClassFilter>(
            groupValue: controller.filter.eventClass,
            children: {
              SoundEventClassFilter.all: Text(strings.all),
              SoundEventClassFilter.bark: Text(strings.bark),
              SoundEventClassFilter.noise: Text(strings.noise),
            },
            onValueChanged: (value) {
              if (controller.canAct && value != null) {
                controller.setFilter(
                  SoundEventFilter(
                    eventClass: value,
                    status: controller.filter.status,
                  ),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          key: const ValueKey('sound-event-status-filter'),
          height: 48,
          child: CupertinoSlidingSegmentedControl<SoundEventStatusFilter>(
            groupValue: controller.filter.status,
            children: {
              SoundEventStatusFilter.all: Text(strings.all),
              SoundEventStatusFilter.unacknowledged: Text(strings.unread),
              SoundEventStatusFilter.acknowledged: Text(strings.reviewed),
            },
            onValueChanged: (value) {
              if (controller.canAct && value != null) {
                controller.setFilter(
                  SoundEventFilter(
                    eventClass: controller.filter.eventClass,
                    status: value,
                  ),
                );
              }
            },
          ),
        ),
      ],
    ),
  );
}

class _LiveStatus extends StatelessWidget {
  const _LiveStatus({required this.controller, required this.strings});
  final SoundEventController controller;
  final _Strings strings;
  @override
  Widget build(BuildContext context) {
    final text = switch (controller.state) {
      SoundEventViewState.idle ||
      SoundEventViewState.loading => strings.loading,
      SoundEventViewState.failed => strings.failed,
      SoundEventViewState.stale => strings.stale,
      SoundEventViewState.verified => strings.verified,
      _ when controller.visibleEvents.isEmpty => strings.empty,
      _ => strings.privacy,
    };
    return Semantics(
      key: const ValueKey('sound-event-live-status'),
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(CupertinoIcons.waveform),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
              if (controller.state == SoundEventViewState.loading ||
                  controller.state == SoundEventViewState.busy)
                const CupertinoActivityIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.strings,
    required this.enabled,
    required this.onAcknowledge,
  });
  final SoundEventItem event;
  final _Strings strings;
  final bool enabled;
  final VoidCallback onAcknowledge;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: SettingsSection(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.className == 'bark' ? strings.bark : strings.noise,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '${(event.confidence * 100).round()}% · ${event.roomId.substring(0, 8)}',
              ),
              const SizedBox(height: 8),
              Text(
                event.automationVerified ? strings.verified : strings.failed,
              ),
            ],
          ),
        ),
        if (!event.acknowledged)
          Semantics(
            key: const ValueKey('sound-event-acknowledge'),
            button: true,
            enabled: enabled,
            label: strings.acknowledge,
            onTap: enabled ? onAcknowledge : null,
            child: ExcludeSemantics(
              child: CupertinoButton(
                minimumSize: const Size(48, 48),
                onPressed: enabled ? onAcknowledge : null,
                child: Text(strings.acknowledge),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(strings.reviewed),
          ),
      ],
    ),
  );
}
