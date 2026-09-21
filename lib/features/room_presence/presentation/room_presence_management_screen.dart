import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/room_presence_management_controller.dart';
import '../domain/room_presence_management_models.dart';

final class _PresenceStrings {
  const _PresenceStrings._(this.tr);
  factory _PresenceStrings.of(BuildContext context) =>
      _PresenceStrings._(Localizations.localeOf(context).languageCode == 'tr');
  final bool tr;

  String get title => tr ? 'Oda varlığı' : 'Room presence';
  String get safety => tr ? 'Mahremiyet ve güven' : 'Privacy and trust';
  String get safetyHint => tr
      ? 'Bu ekran yalnız Core tarafından azaltılmış kanıtı gösterir; kimlik doğrulamaz ve erişim vermez.'
      : 'This screen shows only evidence reduced by Core; it neither authenticates nor grants access.';
  String get advisory => tr ? 'Yalnız öneri' : 'Advisory only';
  String get noHistory => tr
      ? 'Ham BLE/UWB kimliği ve konum geçmişi gösterilmez.'
      : 'Raw BLE/UWB identifiers and location history are never shown.';
  String get loading => tr ? 'Oda kanıtı yükleniyor' : 'Loading room evidence';
  String get empty =>
      tr ? 'Yapılandırılmış cihaz yok' : 'No configured devices';
  String get failed => tr
      ? 'Kanıt doğrulanamadı. Tekrar deneyin.'
      : 'Evidence could not be verified. Try again.';
  String get stale => tr
      ? 'Hesap, oturum veya rota değişti. Kanıt temizlendi.'
      : 'Account, session, or route changed. Evidence was cleared.';
  String get verified => tr
      ? 'Kalibrasyon ve Core okuması doğrulandı.'
      : 'Calibration and Core readback verified.';
  String get retry => tr ? 'Tekrar dene' : 'Retry';
  String get stored => tr ? 'Kayıtlı' : 'Stored';
  String get notStored => tr ? 'Kayıtlı değil' : 'Not stored';
  String get reachable => tr ? 'Kaynak erişilebilir' : 'Provider reachable';
  String get unreachable =>
      tr ? 'Kaynağa erişilemiyor' : 'Provider unreachable';
  String get consent => tr ? 'İzin etkin' : 'Consent active';
  String get noConsent => tr ? 'İzin kapalı' : 'Consent inactive';
  String state(PresenceEvidenceState value) => switch (value) {
    PresenceEvidenceState.unknown => tr ? 'Bilinmiyor' : 'Unknown',
    PresenceEvidenceState.candidate => tr ? 'Aday sinyal' : 'Candidate signal',
    PresenceEvidenceState.uncertain => tr ? 'Belirsiz' : 'Uncertain',
    PresenceEvidenceState.present => tr ? 'Odada olabilir' : 'May be present',
  };
  String confidence(int value) => tr
      ? 'Güven: yüzde ${(value / 10).round()}'
      : 'Confidence: ${(value / 10).round()} percent';
  String get calibrate =>
      tr ? 'Bu oda için kalibre et' : 'Calibrate for this room';
  String get confirmTitle => tr ? 'Kalibrasyonu onayla' : 'Confirm calibration';
  String get confirmBody => tr
      ? 'Core mevcut oda, cihaz, politika, izin ve oturum revizyonlarını yeniden doğrular. Sonuç tekrar okunmadan başarılı sayılmaz.'
      : 'Core revalidates the room, device, policy, consent, and session revisions. Success requires a fresh readback.';
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get confirm => tr ? 'Onayla' : 'Confirm';
  String semantics(RoomPresenceEvidence value) =>
      '${value.deviceName}. ${value.configuredRoomName}. '
      '${value.stored ? stored : notStored}. '
      '${value.providerReachable ? reachable : unreachable}. '
      '${value.consentActive ? consent : noConsent}. ${state(value.state)}. '
      '${confidence(value.confidencePermille)}. $advisory. $noHistory';
}

class RoomPresenceManagementScreen extends StatefulWidget {
  const RoomPresenceManagementScreen({super.key, required this.controller});
  final RoomPresenceManagementController controller;

  @override
  State<RoomPresenceManagementScreen> createState() =>
      _RoomPresenceManagementScreenState();
}

class _RoomPresenceManagementScreenState
    extends State<RoomPresenceManagementScreen> {
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
    _interaction = next;
    _interaction?.addListener(_interactionChanged);
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
  void didUpdateWidget(covariant RoomPresenceManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _viewEpoch++;
    oldWidget.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  @override
  void dispose() {
    _viewEpoch++;
    _interaction?.removeListener(_interactionChanged);
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    super.dispose();
  }

  Future<void> _calibrate(RoomPresenceEvidence evidence) async {
    final epoch = _viewEpoch;
    await widget.controller.previewCalibration(evidence);
    if (!mounted ||
        epoch != _viewEpoch ||
        widget.controller.state !=
            RoomPresenceManagementState.awaitingConfirmation) {
      return;
    }
    final preview = widget.controller.pendingPreview;
    if (preview == null || preview.deviceId != evidence.deviceId) return;
    final strings = _PresenceStrings.of(context);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(strings.confirmTitle),
        content: Text(strings.confirmBody),
        actions: [
          _DialogAction(
            key: const ValueKey('presence-cancel-calibration'),
            label: strings.cancel,
            onPressed: () {
              widget.controller.cancelPending();
              Navigator.of(dialogContext).pop();
            },
          ),
          _DialogAction(
            key: const ValueKey('presence-confirm-calibration'),
            label: strings.confirm,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (mounted && epoch == _viewEpoch) {
                widget.controller.confirmPending();
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = _PresenceStrings.of(context);
    final controller = widget.controller;
    return ServiceRootScaffold(
      title: strings.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(strings.safety),
            footer: Text(strings.safetyHint),
            children: [
              _LiveStatus(controller: controller, strings: strings),
              if (controller.state == RoomPresenceManagementState.failed ||
                  controller.state == RoomPresenceManagementState.stale)
                SettingsActionTile(
                  buttonKey: const ValueKey('presence-retry'),
                  title: Text(strings.retry),
                  leading: const Icon(CupertinoIcons.refresh),
                  onTap: controller.canAct ? controller.load : null,
                ),
            ],
          ),
        ),
        if (controller.evidence.isNotEmpty)
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
                    for (final value in controller.evidence)
                      SizedBox(
                        width: width,
                        child: _EvidenceSection(
                          value: value,
                          strings: strings,
                          enabled:
                              controller.canAct &&
                              value.stored &&
                              value.providerReachable &&
                              value.consentActive,
                          onCalibrate: _calibrate,
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

class _LiveStatus extends StatelessWidget {
  const _LiveStatus({required this.controller, required this.strings});
  final RoomPresenceManagementController controller;
  final _PresenceStrings strings;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (controller.state) {
      RoomPresenceManagementState.idle || RoomPresenceManagementState.loading =>
        (CupertinoIcons.hourglass, strings.loading),
      RoomPresenceManagementState.failed => (
        CupertinoIcons.exclamationmark_triangle,
        strings.failed,
      ),
      RoomPresenceManagementState.stale => (
        CupertinoIcons.lock_shield,
        strings.stale,
      ),
      RoomPresenceManagementState.verified => (
        CupertinoIcons.checkmark_circle,
        strings.verified,
      ),
      _ when controller.evidence.isEmpty => (
        CupertinoIcons.person_2,
        strings.empty,
      ),
      _ => (CupertinoIcons.hand_raised, strings.noHistory),
    };
    return Semantics(
      key: const ValueKey('presence-live-status'),
      container: true,
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 24),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
              if (controller.state == RoomPresenceManagementState.loading ||
                  controller.state == RoomPresenceManagementState.busy)
                const Padding(
                  padding: EdgeInsetsDirectional.only(start: 12),
                  child: CupertinoActivityIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvidenceSection extends StatelessWidget {
  const _EvidenceSection({
    required this.value,
    required this.strings,
    required this.enabled,
    required this.onCalibrate,
  });
  final RoomPresenceEvidence value;
  final _PresenceStrings strings;
  final bool enabled;
  final ValueChanged<RoomPresenceEvidence> onCalibrate;

  @override
  Widget build(BuildContext context) => SettingsSection(
    header: Text(value.configuredRoomName),
    children: [
      Semantics(
        key: ValueKey('presence-state-${value.deviceId}'),
        container: true,
        readOnly: true,
        label: strings.semantics(value),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value.deviceName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _EvidenceLabel(
                      icon: value.providerReachable
                          ? CupertinoIcons.antenna_radiowaves_left_right
                          : CupertinoIcons.exclamationmark_circle,
                      label: value.providerReachable
                          ? strings.reachable
                          : strings.unreachable,
                    ),
                    _EvidenceLabel(
                      icon: value.consentActive
                          ? CupertinoIcons.hand_raised_fill
                          : CupertinoIcons.hand_raised,
                      label: value.consentActive
                          ? strings.consent
                          : strings.noConsent,
                    ),
                    _EvidenceLabel(
                      icon: value.state == PresenceEvidenceState.present
                          ? CupertinoIcons.location_fill
                          : CupertinoIcons.location,
                      label: strings.state(value.state),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(strings.confidence(value.confidencePermille)),
                const SizedBox(height: 6),
                Text(strings.advisory),
                const SizedBox(height: 6),
                Text(
                  strings.noHistory,
                  style: TextStyle(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      SettingsActionTile(
        buttonKey: ValueKey('presence-calibrate-${value.deviceId}'),
        title: Text(strings.calibrate),
        leading: const Icon(CupertinoIcons.scope),
        onTap: enabled ? () => onCalibrate(value) : null,
      ),
    ],
  );
}

class _EvidenceLabel extends StatelessWidget {
  const _EvidenceLabel({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 6),
      Flexible(child: Text(label)),
    ],
  );
}

class _DialogAction extends StatefulWidget {
  const _DialogAction({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback onPressed;

  @override
  State<_DialogAction> createState() => _DialogActionState();
}

class _DialogActionState extends State<_DialogAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: CupertinoDialogAction(
      onPressed: widget.onPressed,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: true,
          label: widget.label,
          onTap: widget.onPressed,
          excludeSemantics: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                width: 2,
                color: _focused
                    ? CupertinoTheme.of(context).primaryColor
                    : CupertinoColors.transparent,
              ),
              borderRadius: BorderRadius.circular(5),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Center(child: Text(widget.label)),
            ),
          ),
        ),
      ),
    ),
  );
}
