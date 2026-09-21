import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/epaper_management_controller.dart';
import '../domain/epaper_management_models.dart';

final class _EpaperStrings {
  const _EpaperStrings._({required this.tr});

  factory _EpaperStrings.of(BuildContext context) => _EpaperStrings._(
    tr: Localizations.localeOf(context).languageCode == 'tr',
  );

  final bool tr;
  String get title => tr ? 'E-paper ekranlar' : 'E-paper displays';
  String get overview => tr ? 'Güvenli durum' : 'Safe status';
  String get overviewHint => tr
      ? 'Kayıt, erişim ve doğrulanmış görüntü ayrı kanıtlardır.'
      : 'Stored, reachable, and verified image are separate evidence.';
  String get loading => tr ? 'Ekranlar yükleniyor' : 'Loading displays';
  String get empty => tr ? 'Kayıtlı ekran yok' : 'No stored displays';
  String get failed => tr
      ? 'Durum doğrulanamadı. Tekrar deneyin.'
      : 'Status could not be verified. Try again.';
  String get stale => tr
      ? 'Oturum veya ekran görünürlüğü değişti. Durum temizlendi.'
      : 'Session or screen visibility changed. Status was cleared.';
  String get verifiedAction => tr
      ? 'İşlem ve yeni ekran durumu doğrulandı.'
      : 'Action and new display state verified.';
  String get pendingDelivery => tr
      ? 'Görüntü yayınlandı; cihaz teslim doğrulaması bekleniyor.'
      : 'Snapshot published; waiting for device delivery verification.';
  String get retry => tr ? 'Tekrar dene' : 'Retry';
  String get add => tr ? 'Ekran eşle' : 'Map display';
  String get addTitle => tr ? 'E-paper ekran eşle' : 'Map e-paper display';
  String get deviceId => tr ? 'Cihaz kimliği' : 'Device ID';
  String get name => tr ? 'Ekran adı' : 'Display name';
  String get save => tr ? 'Eşle' : 'Map';
  String get invalid => tr
      ? '32 karakterli küçük harfli onaltılık cihaz kimliği girin.'
      : 'Enter a 32-character lowercase hexadecimal device ID.';
  String get preview => tr ? 'Görüntü önizlemesi' : 'Display preview';
  String get stored => tr ? 'Kayıtlı' : 'Stored';
  String get notStored => tr ? 'Kayıtlı değil' : 'Not stored';
  String get reachable => tr ? 'Erişilebilir' : 'Reachable';
  String get unreachable => tr ? 'Erişilemiyor' : 'Unreachable';
  String trust(EpaperSnapshotTrust value) => switch (value) {
    EpaperSnapshotTrust.empty => tr ? 'Görüntü yok' : 'No snapshot',
    EpaperSnapshotTrust.pending => tr ? 'Bekliyor' : 'Pending',
    EpaperSnapshotTrust.partial => tr ? 'Kısmi' : 'Partial',
    EpaperSnapshotTrust.verified => tr ? 'Doğrulandı' : 'Verified',
    EpaperSnapshotTrust.stale => tr ? 'Güncel değil' : 'Stale',
  };
  String get refresh => tr ? 'Ekranı yenile' : 'Refresh display';
  String confirmTitle(EpaperManagementAction action) => switch (action) {
    EpaperManagementAction.refresh =>
      tr ? 'Ekran yenilensin mi?' : 'Refresh this display?',
  };
  String confirmBody(EpaperManagementAction action) => switch (action) {
    EpaperManagementAction.refresh =>
      tr
          ? 'Larenor Core güncel görüntüyü hazırlayıp cihaza iletecek. Sonuç cihazdan tekrar okunmadan başarılı sayılmaz.'
          : 'Larenor Core will prepare and deliver the current image. Success requires a device readback.',
  };
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get confirm => tr ? 'Onayla' : 'Confirm';
  String deviceState(EpaperDeviceStatus device) =>
      '${device.name}. ${device.stored ? stored : notStored}. '
      '${device.reachable ? reachable : unreachable}. '
      '${trust(device.snapshotTrust)}.';
}

class EpaperManagementScreen extends StatefulWidget {
  const EpaperManagementScreen({super.key, required this.controller});

  final EpaperManagementController controller;

  @override
  State<EpaperManagementScreen> createState() => _EpaperManagementScreenState();
}

class _EpaperManagementScreenState extends State<EpaperManagementScreen> {
  AppInteractionController? _interaction;
  int _viewEpoch = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.load();
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
  void didUpdateWidget(covariant EpaperManagementScreen oldWidget) {
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

  Future<void> _request(
    EpaperDeviceStatus device,
    EpaperManagementAction action,
  ) async {
    final epoch = _viewEpoch;
    await widget.controller.preview(device, action);
    if (!mounted ||
        epoch != _viewEpoch ||
        widget.controller.state != EpaperManagementState.awaitingConfirmation) {
      return;
    }
    final preview = widget.controller.pendingPreview;
    if (preview == null || preview.deviceId != device.deviceId) return;
    final strings = _EpaperStrings.of(context);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(strings.confirmTitle(action)),
        content: Text(strings.confirmBody(action)),
        actions: [
          _EpaperDialogAction(
            key: const ValueKey('epaper-cancel-action'),
            label: strings.cancel,
            onPressed: () {
              unawaited(widget.controller.cancelPending());
              Navigator.of(dialogContext).pop();
            },
          ),
          _EpaperDialogAction(
            key: const ValueKey('epaper-confirm-action'),
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

  Future<void> _map() async {
    if (!widget.controller.canAct) return;
    final epoch = _viewEpoch;
    final draft = await Navigator.of(context).push<EpaperDeviceMappingDraft>(
      CupertinoPageRoute(
        builder: (_) => _MappingScreen(strings: _EpaperStrings.of(context)),
      ),
    );
    if (!mounted || epoch != _viewEpoch || draft == null) return;
    await widget.controller.map(draft);
  }

  @override
  Widget build(BuildContext context) {
    final strings = _EpaperStrings.of(context);
    final controller = widget.controller;
    return ServiceRootScaffold(
      title: strings.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(strings.overview),
            footer: Text(strings.overviewHint),
            children: [
              _StatusMessage(controller: controller, strings: strings),
              if (controller.authority.canManage)
                SettingsActionTile(
                  buttonKey: const ValueKey('epaper-map-display'),
                  title: Text(strings.add),
                  leading: const Icon(CupertinoIcons.plus_rectangle),
                  onTap: controller.canAct ? _map : null,
                ),
              if (controller.state == EpaperManagementState.failed ||
                  controller.state == EpaperManagementState.stale)
                SettingsActionTile(
                  buttonKey: const ValueKey('epaper-retry'),
                  title: Text(strings.retry),
                  leading: const Icon(CupertinoIcons.refresh),
                  onTap: controller.canAct ? controller.load : null,
                ),
            ],
          ),
        ),
        if (controller.devices.isNotEmpty)
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900 ? 2 : 1;
                final available = constraints.maxWidth - 16 * (columns + 1);
                final width = available / columns;
                return Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  children: [
                    for (final device in controller.devices)
                      SizedBox(
                        width: width,
                        child: _DeviceSection(
                          device: device,
                          strings: strings,
                          enabled:
                              controller.canAct &&
                              device.stored &&
                              device.reachable,
                          onAction: _request,
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

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.controller, required this.strings});

  final EpaperManagementController controller;
  final _EpaperStrings strings;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (controller.state) {
      EpaperManagementState.idle || EpaperManagementState.loading => (
        CupertinoIcons.hourglass,
        strings.loading,
      ),
      EpaperManagementState.failed => (
        CupertinoIcons.exclamationmark_triangle,
        strings.failed,
      ),
      EpaperManagementState.stale => (
        CupertinoIcons.lock_shield,
        strings.stale,
      ),
      EpaperManagementState.verified => (
        CupertinoIcons.checkmark_circle,
        strings.verifiedAction,
      ),
      EpaperManagementState.pendingDelivery => (
        CupertinoIcons.clock,
        strings.pendingDelivery,
      ),
      _ when controller.devices.isEmpty => (
        CupertinoIcons.rectangle_stack,
        strings.empty,
      ),
      _ => (CupertinoIcons.checkmark_shield, strings.overviewHint),
    };
    return Semantics(
      key: const ValueKey('epaper-live-status'),
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
              if (controller.state == EpaperManagementState.loading ||
                  controller.state == EpaperManagementState.busy)
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

class _DeviceSection extends StatelessWidget {
  const _DeviceSection({
    required this.device,
    required this.strings,
    required this.enabled,
    required this.onAction,
  });

  final EpaperDeviceStatus device;
  final _EpaperStrings strings;
  final bool enabled;
  final void Function(EpaperDeviceStatus, EpaperManagementAction) onAction;

  @override
  Widget build(BuildContext context) => SettingsSection(
    header: Text(device.name),
    children: [
      Semantics(
        key: ValueKey('epaper-state-${device.deviceId}'),
        container: true,
        readOnly: true,
        label: strings.deviceState(device),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _Evidence(
                  icon: device.stored
                      ? CupertinoIcons.tray_full
                      : CupertinoIcons.tray,
                  label: device.stored ? strings.stored : strings.notStored,
                ),
                _Evidence(
                  icon: device.reachable
                      ? CupertinoIcons.antenna_radiowaves_left_right
                      : CupertinoIcons.exclamationmark_circle,
                  label: device.reachable
                      ? strings.reachable
                      : strings.unreachable,
                ),
                _Evidence(
                  icon: device.snapshotTrust == EpaperSnapshotTrust.verified
                      ? CupertinoIcons.checkmark_shield
                      : CupertinoIcons.clock,
                  label: strings.trust(device.snapshotTrust),
                ),
              ],
            ),
          ),
        ),
      ),
      _EpaperPreview(device: device, strings: strings),
      SettingsActionTile(
        buttonKey: ValueKey('epaper-refresh-${device.deviceId}'),
        title: Text(strings.refresh),
        leading: const Icon(CupertinoIcons.refresh),
        onTap: enabled
            ? () => onAction(device, EpaperManagementAction.refresh)
            : null,
      ),
    ],
  );
}

class _EpaperPreview extends StatelessWidget {
  const _EpaperPreview({required this.device, required this.strings});

  final EpaperDeviceStatus device;
  final _EpaperStrings strings;

  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('epaper-preview-${device.deviceId}'),
    container: true,
    readOnly: true,
    label: '${strings.preview}. ${strings.deviceState(device)}',
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: AspectRatio(
          aspectRatio: 5 / 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CupertinoColors.white,
              border: Border.all(color: CupertinoColors.black, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.clock,
                      color: CupertinoColors.black,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      device.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: CupertinoColors.black,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      strings.trust(device.snapshotTrust),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: CupertinoColors.black),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _MappingScreen extends StatefulWidget {
  const _MappingScreen({required this.strings});
  final _EpaperStrings strings;

  @override
  State<_MappingScreen> createState() => _MappingScreenState();
}

class _MappingScreenState extends State<_MappingScreen> {
  final _device = TextEditingController();
  final _name = TextEditingController();
  bool _attempted = false;

  EpaperDeviceMappingDraft get _draft =>
      EpaperDeviceMappingDraft(deviceId: _device.text, name: _name.text);

  @override
  void dispose() {
    _device.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _draft;
    if (!value.isValid) {
      setState(() => _attempted = true);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(widget.strings.addTitle),
    ),
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Semantics(
            textField: true,
            label: widget.strings.deviceId,
            child: SizedBox(
              height: 48,
              child: CupertinoTextField(
                key: const ValueKey('epaper-map-device-id'),
                controller: _device,
                minLines: 1,
                maxLines: 1,
                placeholder: widget.strings.deviceId,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            textField: true,
            label: widget.strings.name,
            child: SizedBox(
              height: 48,
              child: CupertinoTextField(
                key: const ValueKey('epaper-map-name'),
                controller: _name,
                minLines: 1,
                maxLines: 1,
                placeholder: widget.strings.name,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: CupertinoButton.filled(
              key: const ValueKey('epaper-map-submit'),
              onPressed: _submit,
              child: Text(widget.strings.save),
            ),
          ),
          if (_attempted && !_draft.isValid)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  widget.strings.invalid,
                  style: TextStyle(
                    color: CupertinoColors.systemRed.resolveFrom(context),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Evidence extends StatelessWidget {
  const _Evidence({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)],
  );
}

class _EpaperDialogAction extends StatefulWidget {
  const _EpaperDialogAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  State<_EpaperDialogAction> createState() => _EpaperDialogActionState();
}

class _EpaperDialogActionState extends State<_EpaperDialogAction> {
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
