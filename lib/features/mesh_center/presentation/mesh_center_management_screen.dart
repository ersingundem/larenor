import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/mesh_center_management_controller.dart';
import '../domain/mesh_center_models.dart';

final class _MeshStrings {
  const _MeshStrings._(this.tr);
  factory _MeshStrings.of(BuildContext context) =>
      _MeshStrings._(Localizations.localeOf(context).languageCode == 'tr');
  final bool tr;

  String get title => tr ? 'Zigbee ve Thread ağı' : 'Zigbee & Thread network';
  String get topology => tr ? 'Ağ durumu' : 'Network status';
  String get devices => tr ? 'Cihazlar' : 'Devices';
  String get readOnly => tr ? 'Salt okunur öneri' : 'Read-only advisory';
  String get loading => tr ? 'Ağ durumu yükleniyor' : 'Loading network status';
  String get failed => tr
      ? 'Durum veya işlem sonucu doğrulanamadı. Güncelleme tekrarlanmadı.'
      : 'Status or operation result could not be verified. The update was not replayed.';
  String get stale => tr
      ? 'Hesap, oturum veya rota değişti. Ağ durumu temizlendi.'
      : 'Account, session, or route changed. Network state was cleared.';
  String get verified => tr
      ? 'Firmware güncellemesi readback ile doğrulandı.'
      : 'Firmware update was verified by readback.';
  String get empty => tr ? 'Ağ cihazı bulunamadı' : 'No network devices';
  String get reload => tr ? 'Tekrar yükle' : 'Reload';
  String channel(MeshCenterSnapshot value) => tr
      ? 'Kanal ${value.channel}; önerilen ${value.recommendedChannel}. Kullanım %${value.channelUtilizationPercent}; önerilen %${value.recommendedUtilizationPercent}.'
      : 'Channel ${value.channel}; recommended ${value.recommendedChannel}. Utilization ${value.channelUtilizationPercent}%; recommended ${value.recommendedUtilizationPercent}%.';
  String routers(MeshCenterSnapshot value) => tr
      ? '${value.borderRouterCount} sınır yönlendirici, ${value.offlineBorderRouterCount} çevrimdışı'
      : '${value.borderRouterCount} border routers, ${value.offlineBorderRouterCount} offline';
  String get reachable => tr ? 'Erişilebilir' : 'Reachable';
  String get unreachable => tr ? 'Erişilemiyor' : 'Unreachable';
  String get signed => tr ? 'İmza doğrulandı' : 'Signature verified';
  String get noUpdate => tr ? 'Güvenli güncelleme yok' : 'No safe update';
  String update(String version) =>
      tr ? '$version sürümüne güncelle' : 'Update to $version';
  String get confirmTitle =>
      tr ? 'Firmware güncellensin mi?' : 'Update firmware?';
  String confirmBody(MeshClientDevice device) => tr
      ? '${device.name} yalnız doğrulanmış firmware ve mevcut ağ revizyonlarıyla güncellenecek. İşlem sonucu readback olmadan başarılı sayılmaz.'
      : '${device.name} will update only with verified firmware and the current network revisions. Success requires exact readback.';
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get confirm => tr ? 'Güncelle' : 'Update';
}

class MeshCenterManagementScreen extends StatefulWidget {
  const MeshCenterManagementScreen({super.key, required this.controller});
  final MeshCenterManagementController controller;

  @override
  State<MeshCenterManagementScreen> createState() =>
      _MeshCenterManagementScreenState();
}

class _MeshCenterManagementScreenState
    extends State<MeshCenterManagementScreen> {
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
  void didUpdateWidget(covariant MeshCenterManagementScreen oldWidget) {
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

  Future<void> _requestUpdate(MeshClientDevice device) async {
    final epoch = _viewEpoch;
    await widget.controller.previewUpdate(device);
    if (!mounted ||
        epoch != _viewEpoch ||
        widget.controller.state !=
            MeshCenterManagementState.awaitingConfirmation ||
        widget.controller.pendingPreview?.deviceId != device.deviceId) {
      return;
    }
    final strings = _MeshStrings.of(context);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(strings.confirmTitle),
        content: Text(strings.confirmBody(device)),
        actions: [
          _DialogAction(
            label: strings.cancel,
            onPressed: () {
              widget.controller.cancelPending();
              Navigator.of(dialogContext).pop();
            },
          ),
          _DialogAction(
            key: const ValueKey('mesh-confirm-update'),
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
    final strings = _MeshStrings.of(context);
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return ServiceRootScaffold(
      title: strings.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(strings.topology),
            footer: snapshot == null ? null : Text(strings.readOnly),
            children: [
              _LiveStatus(controller: controller, strings: strings),
              if (snapshot != null)
                _TopologyStatus(snapshot: snapshot, strings: strings),
              if (controller.state == MeshCenterManagementState.failed ||
                  controller.state == MeshCenterManagementState.stale)
                SettingsActionTile(
                  buttonKey: const ValueKey('mesh-reload'),
                  title: Text(strings.reload),
                  leading: const Icon(CupertinoIcons.refresh),
                  onTap: controller.canAct ? controller.load : null,
                ),
            ],
          ),
        ),
        if (snapshot != null && snapshot.devices.isNotEmpty)
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
                    for (final device in snapshot.devices)
                      SizedBox(
                        width: width,
                        child: _DeviceSection(
                          device: device,
                          strings: strings,
                          enabled: controller.canUpdateDevice(device),
                          onUpdate: () => _requestUpdate(device),
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
  final MeshCenterManagementController controller;
  final _MeshStrings strings;

  @override
  Widget build(BuildContext context) {
    final text = switch (controller.state) {
      MeshCenterManagementState.idle ||
      MeshCenterManagementState.loading => strings.loading,
      MeshCenterManagementState.failed => strings.failed,
      MeshCenterManagementState.stale => strings.stale,
      MeshCenterManagementState.verified => strings.verified,
      _ when controller.snapshot?.devices.isEmpty ?? true => strings.empty,
      _ => strings.readOnly,
    };
    return Semantics(
      key: const ValueKey('mesh-live-status'),
      container: true,
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                CupertinoIcons.antenna_radiowaves_left_right,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
              if (controller.state == MeshCenterManagementState.loading ||
                  controller.state == MeshCenterManagementState.busy)
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

class _TopologyStatus extends StatelessWidget {
  const _TopologyStatus({required this.snapshot, required this.strings});
  final MeshCenterSnapshot snapshot;
  final _MeshStrings strings;

  @override
  Widget build(BuildContext context) {
    final label =
        '${strings.readOnly}. ${strings.channel(snapshot)} '
        '${strings.routers(snapshot)}.';
    return Semantics(
      key: const ValueKey('mesh-topology-status'),
      container: true,
      readOnly: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _Evidence(
                icon: CupertinoIcons.chart_bar,
                label: strings.channel(snapshot),
              ),
              _Evidence(
                icon: CupertinoIcons.arrow_branch,
                label: strings.routers(snapshot),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  const _DeviceSection({
    required this.device,
    required this.strings,
    required this.enabled,
    required this.onUpdate,
  });
  final MeshClientDevice device;
  final _MeshStrings strings;
  final bool enabled;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final offer = device.update;
    return SettingsSection(
      header: Text(device.name),
      children: [
        Semantics(
          container: true,
          readOnly: true,
          label:
              '${device.name}. '
              '${device.reachable ? strings.reachable : strings.unreachable}. '
              '${offer?.signedMetadataVerified == true ? strings.signed : strings.noUpdate}.',
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _Evidence(
                    icon: device.reachable
                        ? CupertinoIcons.checkmark_circle
                        : CupertinoIcons.exclamationmark_circle,
                    label: device.reachable
                        ? strings.reachable
                        : strings.unreachable,
                  ),
                  _Evidence(
                    icon: CupertinoIcons.shield,
                    label: offer?.signedMetadataVerified == true
                        ? strings.signed
                        : strings.noUpdate,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (offer != null)
          Semantics(
            key: ValueKey('mesh-update-${device.deviceId}'),
            button: true,
            enabled: enabled,
            label: strings.update(offer.targetVersion),
            onTap: enabled ? onUpdate : null,
            excludeSemantics: true,
            child: SettingsActionTile(
              title: _KeyboardLabel(
                label: strings.update(offer.targetVersion),
                onActivate: enabled ? onUpdate : null,
              ),
              leading: const Icon(CupertinoIcons.arrow_down_circle),
              onTap: enabled ? onUpdate : null,
            ),
          ),
      ],
    );
  }
}

class _KeyboardLabel extends StatelessWidget {
  const _KeyboardLabel({required this.label, required this.onActivate});
  final String label;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: onActivate != null,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space)) {
        onActivate?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Text(label),
  );
}

class _Evidence extends StatelessWidget {
  const _Evidence({required this.icon, required this.label});
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
