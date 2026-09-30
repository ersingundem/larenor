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
  String get refreshSource =>
      tr ? 'Frigate olaylarını yenile' : 'Refresh Frigate events';
  String get configureSource =>
      tr ? 'Ses kaynağı ayarları' : 'Sound source settings';
  String get acknowledge => tr ? 'Okundu olarak işaretle' : 'Mark as reviewed';
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get confirm => tr ? 'Onayla' : 'Confirm';
  String get all => tr ? 'Tümü' : 'All';
  String get bark => tr ? 'Havlama' : 'Bark';
  String get noise => tr ? 'Diğer ses' : 'Other noise';
  String get unread => tr ? 'Yeni' : 'New';
  String get reviewed => tr ? 'İncelendi' : 'Reviewed';
  String get sourceReady => tr ? 'Kaynak güncel' : 'Source is current';
  String get sourceUnavailable =>
      tr ? 'Ses olay kaynağı kullanılamıyor' : 'Sound event source unavailable';
  String get sourceStale =>
      tr ? 'Kaynak verisi güncel değil' : 'Source data is not current';
  String get noQuietProof => tr
      ? 'Olay olmaması ortamın sessiz olduğunu kanıtlamaz.'
      : 'No event does not prove that the room is quiet.';
  String get notificationPolicy =>
      tr ? 'Bildirim ilkesi' : 'Notification policy';
  String get notifications => tr ? 'Bildirimler' : 'Notifications';
  String get barkNotifications =>
      tr ? 'Havlama bildirimleri' : 'Bark notifications';
  String get noiseNotifications =>
      tr ? 'Gürültü bildirimleri' : 'Noise notifications';
  String get muteOneHour => tr ? '1 saat sessize al' : 'Mute for 1 hour';
  String get unmute => tr ? 'Sessizi kaldır' : 'Unmute';
  String get muted => tr ? 'Bildirimler sessizde' : 'Notifications muted';
  String get sourceClipsNever => tr
      ? 'Kaynak ses klipleri saklanmaz.'
      : 'Source sound clips are never retained.';
  String get falseAlarm => tr ? 'Yanlış alarm' : 'False alarm';
  String get confirmedEvent => tr ? 'Doğrulandı' : 'Confirmed';
  String get providerEvent => tr ? 'Sağlayıcı olayı' : 'Provider event';
  String get automationNotVerified => tr
      ? 'Otomasyon teslimi doğrulanmadı'
      : 'Automation delivery not verified';
  String get notificationEligible =>
      tr ? 'Bildirim için uygun' : 'Eligible for notification';
  String get notificationSuppressed =>
      tr ? 'Bildirim bastırıldı' : 'Notification suppressed';
  String duration(Duration value) => tr
      ? '${(value.inMilliseconds / 1000).toStringAsFixed(1)} sn'
      : '${(value.inMilliseconds / 1000).toStringAsFixed(1)} sec';
}

class SoundEventScreen extends StatefulWidget {
  const SoundEventScreen({
    super.key,
    required this.controller,
    this.onRefreshSource,
    this.onConfigureSource,
    this.sourceSetupFailed = false,
  });
  final SoundEventController controller;
  final Future<void> Function()? onRefreshSource;
  final VoidCallback? onConfigureSource;
  final bool sourceSetupFailed;
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
              if (controller.snapshot case final snapshot?)
                _SourceStatus(status: snapshot.sourceStatus, strings: strings),
              if (widget.onRefreshSource case final refresh?)
                SettingsActionTile(
                  buttonKey: const ValueKey('sound-event-source-refresh'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(strings.refreshSource),
                  onTap: controller.canAct ? refresh : null,
                ),
              if (widget.onConfigureSource case final configure?)
                SettingsActionTile(
                  buttonKey: const ValueKey('sound-event-source-settings'),
                  leading: const Icon(CupertinoIcons.settings),
                  title: Text(strings.configureSource),
                  additionalInfo: widget.sourceSetupFailed
                      ? Text(
                          strings.tr
                              ? 'Kaynak ayarları yüklenemedi. Yeniden denemek için dokunun.'
                              : 'Source settings could not be loaded. Tap to retry.',
                        )
                      : null,
                  onTap: controller.canAct ? configure : null,
                ),
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
                          feedbackEnabled:
                              controller.canAct && controller.canControl,
                          onFalseAlarm: () =>
                              controller.markFeedback(event, 'false_alarm'),
                          onConfirmEvent: () =>
                              controller.markFeedback(event, 'confirmed'),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        if (controller.snapshot case final snapshot?)
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(strings.notificationPolicy),
              footer: Text(strings.sourceClipsNever),
              children: [
                _PolicyControls(
                  controller: controller,
                  policy: snapshot.policy,
                  strings: strings,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SourceStatus extends StatelessWidget {
  const _SourceStatus({required this.status, required this.strings});
  final SoundSourceStatus status;
  final _Strings strings;

  @override
  Widget build(BuildContext context) {
    final statusText = switch (status.state) {
      'ready' when status.current => strings.sourceReady,
      'unavailable' => strings.sourceUnavailable,
      _ => strings.sourceStale,
    };
    return Padding(
      key: const ValueKey('sound-event-source-status'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                status.current
                    ? CupertinoIcons.check_mark_circled_solid
                    : CupertinoIcons.exclamationmark_triangle,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(statusText)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            strings.noQuietProof,
            style: TextStyle(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicyControls extends StatelessWidget {
  const _PolicyControls({
    required this.controller,
    required this.policy,
    required this.strings,
  });
  final SoundEventController controller;
  final SoundEventPolicy policy;
  final _Strings strings;

  bool get _enabled => controller.canAct && controller.canControl;

  void _update({
    bool? notifications,
    bool? bark,
    bool? noise,
    DateTime? mute,
    bool keepMute = true,
  }) {
    controller.updatePolicy(
      notificationsEnabled: notifications ?? policy.notificationsEnabled,
      barkEnabled: bark ?? policy.barkEnabled,
      noiseEnabled: noise ?? policy.noiseEnabled,
      mutedUntil: keepMute ? policy.mutedUntil : mute,
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _PolicySwitch(
        key: const ValueKey('sound-event-notifications-toggle'),
        label: strings.notifications,
        value: policy.notificationsEnabled,
        enabled: _enabled,
        onChanged: (value) => _update(notifications: value),
      ),
      _PolicySwitch(
        label: strings.barkNotifications,
        value: policy.barkEnabled,
        enabled: _enabled && policy.notificationsEnabled,
        onChanged: (value) => _update(bark: value),
      ),
      _PolicySwitch(
        label: strings.noiseNotifications,
        value: policy.noiseEnabled,
        enabled: _enabled && policy.notificationsEnabled,
        onChanged: (value) => _update(noise: value),
      ),
      SettingsActionTile(
        buttonKey: const ValueKey('sound-event-mute-toggle'),
        leading: Icon(
          policy.muted ? CupertinoIcons.bell_slash_fill : CupertinoIcons.bell,
        ),
        title: Text(policy.muted ? strings.unmute : strings.muteOneHour),
        additionalInfo: policy.muted ? Text(strings.muted) : null,
        onTap: !_enabled
            ? null
            : () {
                if (policy.muted) {
                  _update(keepMute: false);
                } else {
                  _update(
                    mute: DateTime.now().toUtc().add(const Duration(hours: 1)),
                    keepMute: false,
                  );
                }
              },
      ),
    ],
  );
}

class _PolicySwitch extends StatelessWidget {
  const _PolicySwitch({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });
  final String label;
  final bool value, enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        CupertinoSwitch(value: value, onChanged: enabled ? onChanged : null),
      ],
    ),
  );
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
    required this.feedbackEnabled,
    required this.onFalseAlarm,
    required this.onConfirmEvent,
  });
  final SoundEventItem event;
  final _Strings strings;
  final bool enabled;
  final VoidCallback onAcknowledge;
  final bool feedbackEnabled;
  final VoidCallback onFalseAlarm, onConfirmEvent;
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
                '${event.confidence == 1 && !event.automationVerified ? strings.providerEvent : '${(event.confidence * 100).round()}%'} · ${strings.duration(event.duration)} · ${event.roomId.substring(0, 8)}',
              ),
              const SizedBox(height: 8),
              Text(
                event.automationVerified
                    ? strings.verified
                    : strings.automationNotVerified,
              ),
              const SizedBox(height: 8),
              Text(
                event.notificationEligible
                    ? strings.notificationEligible
                    : strings.notificationSuppressed,
              ),
              if (event.feedback case final feedback?) ...[
                const SizedBox(height: 8),
                Text(
                  feedback == 'false_alarm'
                      ? strings.falseAlarm
                      : strings.confirmedEvent,
                ),
              ],
            ],
          ),
        ),
        if (event.feedback == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    key: const ValueKey('sound-event-false-alarm'),
                    onPressed: feedbackEnabled ? onFalseAlarm : null,
                    child: Text(strings.falseAlarm),
                  ),
                ),
                Expanded(
                  child: CupertinoButton(
                    key: const ValueKey('sound-event-confirm-event'),
                    onPressed: feedbackEnabled ? onConfirmEvent : null,
                    child: Text(strings.confirmedEvent),
                  ),
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
