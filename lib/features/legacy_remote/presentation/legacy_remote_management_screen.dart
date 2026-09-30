import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/legacy_remote_management_api.dart';
import '../data/legacy_remote_management_controller.dart';
import '../domain/legacy_remote_models.dart';

final class _RemoteStrings {
  const _RemoteStrings._(this.tr);
  factory _RemoteStrings.of(BuildContext context) =>
      _RemoteStrings._(Localizations.localeOf(context).languageCode == 'tr');
  final bool tr;

  String get title => tr ? 'Akıllı kumandalar' : 'Smart remotes';
  String get safety => tr ? 'Güvenli komut durumu' : 'Safe command status';
  String get safetyHint => tr
      ? 'Sinyal teslimi ile cihazın fiziksel durumu ayrı kanıtlardır.'
      : 'Signal delivery and physical device state are separate evidence.';
  String get loading => tr ? 'Kumandalar yükleniyor' : 'Loading remotes';
  String get empty => tr ? 'Kayıtlı kumanda yok' : 'No stored remotes';
  String get failed => tr
      ? 'Komut sonucu doğrulanamadı. Otomatik tekrar yapılmadı.'
      : 'Command result was not verified. It was not replayed.';
  String get stale => tr
      ? 'Hesap, oturum veya rota değişti. Durum temizlendi.'
      : 'Account, session, or route changed. State was cleared.';
  String get delivered =>
      tr ? 'Sinyal teslimi doğrulandı.' : 'Signal delivery verified.';
  String get learned => tr
      ? 'Öğrenilen tuş kalıcı olarak doğrulandı.'
      : 'The learned button was durably verified.';
  String get deviceUnverified =>
      tr ? 'Cihaz durumu doğrulanmadı' : 'Device state not verified';
  String get retry => tr ? 'Tekrar yükle' : 'Reload';
  String get stored => tr ? 'Kayıtlı' : 'Stored';
  String get notStored => tr ? 'Kayıtlı değil' : 'Not stored';
  String get reachable => tr ? 'Erişilebilir' : 'Reachable';
  String get unreachable => tr ? 'Erişilemiyor' : 'Unreachable';
  String get providerVerified =>
      tr ? 'Sağlayıcı doğrulandı' : 'Provider verified';
  String get providerUnverified =>
      tr ? 'Sağlayıcı doğrulanmadı' : 'Provider not verified';
  String get confirmTitle => tr ? 'Komutu gönder?' : 'Send command?';
  String confirmBody(String command, String device) => tr
      ? '$device için “$command” sinyali gönderilecek. Köprüye gönderim istenecektir; sinyalin ulaştığı veya cihazın durumu doğrulanamaz.'
      : 'The “$command” signal will be sent to $device. This requests bridge transmission; signal delivery and device state cannot be verified.';
  String get cancel => tr ? 'Vazgeç' : 'Cancel';
  String get confirm => tr ? 'Gönder' : 'Send';
  String get learn => tr ? 'Tuş öğren' : 'Learn a button';
  String get chooseKey => tr ? 'Öğrenilecek tuş' : 'Button to learn';
  String get learnTitle => tr ? 'Sinyali öğren?' : 'Learn this signal?';
  String learnBody(String command, String device) => tr
      ? 'Orijinal kumandayı $device köprüsüne doğrultun. “$command” tuşuna bastıktan sonra Öğren ile başlatın. Bu işlem cihazın fiziksel durumunu değiştirmez veya doğrulamaz.'
      : 'Point the original remote at the $device bridge. Press “$command”, then start Learn. This does not change or verify the appliance state.';
  String get startLearning => tr ? 'Öğren' : 'Learn';
  String get setup => tr ? 'Kumanda kaynağı ekle' : 'Add remote source';
  String get setupTitle => tr ? 'Broadlink IR kaynağı' : 'Broadlink IR source';
  String get setupHint => tr
      ? 'Home Assistant içinde önceden öğrenilmiş tek bir IR komutunu bağlar. Ham sinyal verisi Larenor’a kopyalanmaz.'
      : 'Binds one IR command already learned in Home Assistant. Raw signal data is not copied into Larenor.';
  String get sourceName => tr ? 'Kumanda adı' : 'Remote name';
  String get entityId => tr ? 'Remote varlık kimliği' : 'Remote entity ID';
  String get learnedDevice =>
      tr ? 'Öğrenilmiş cihaz adı' : 'Learned device name';
  String get learnedCommand =>
      tr ? 'Öğrenilmiş komut adı' : 'Learned command name';
  String get service =>
      tr ? 'Home Assistant servisi' : 'Home Assistant service';
  String get commandKey => tr ? 'Mantıksal tuş' : 'Logical button';
  String get save =>
      tr ? 'Kaynağı doğrula ve kaydet' : 'Verify and save source';
  String get noService => tr
      ? 'Doğrulanmış Home Assistant servisi yok'
      : 'No authenticated Home Assistant service';
  String get setupFailed => tr
      ? 'Kaynak doğrulanamadı veya kaydedilemedi.'
      : 'The source could not be verified or saved.';
  String get savedSources => tr ? 'Kaydedilmiş kaynaklar' : 'Saved sources';
  String command(LegacyRemoteCommandKey key) => switch (key) {
    LegacyRemoteCommandKey.powerToggle => tr ? 'Güç' : 'Power',
    LegacyRemoteCommandKey.powerOn => tr ? 'Aç' : 'Power on',
    LegacyRemoteCommandKey.powerOff => tr ? 'Kapat' : 'Power off',
    LegacyRemoteCommandKey.volumeUp => tr ? 'Sesi artır' : 'Volume up',
    LegacyRemoteCommandKey.volumeDown => tr ? 'Sesi azalt' : 'Volume down',
    LegacyRemoteCommandKey.mute => tr ? 'Sessiz' : 'Mute',
    LegacyRemoteCommandKey.channelUp => tr ? 'Kanal ileri' : 'Channel up',
    LegacyRemoteCommandKey.channelDown => tr ? 'Kanal geri' : 'Channel down',
    LegacyRemoteCommandKey.inputNext => tr ? 'Sonraki giriş' : 'Next input',
    LegacyRemoteCommandKey.menu => tr ? 'Menü' : 'Menu',
    LegacyRemoteCommandKey.back => tr ? 'Geri' : 'Back',
    LegacyRemoteCommandKey.up => tr ? 'Yukarı' : 'Up',
    LegacyRemoteCommandKey.down => tr ? 'Aşağı' : 'Down',
    LegacyRemoteCommandKey.left => tr ? 'Sol' : 'Left',
    LegacyRemoteCommandKey.right => tr ? 'Sağ' : 'Right',
    LegacyRemoteCommandKey.select => tr ? 'Seç' : 'Select',
    LegacyRemoteCommandKey.play => tr ? 'Oynat' : 'Play',
    LegacyRemoteCommandKey.pause => tr ? 'Duraklat' : 'Pause',
    LegacyRemoteCommandKey.stop => tr ? 'Durdur' : 'Stop',
  };
  String semantics(LegacyRemoteDevice value) =>
      '${value.name}. ${value.stored ? stored : notStored}. '
      '${value.reachable ? reachable : unreachable}. '
      '${value.providerVerified ? providerVerified : providerUnverified}. '
      '$deviceUnverified.';
}

class LegacyRemoteManagementScreen extends StatefulWidget {
  const LegacyRemoteManagementScreen({
    super.key,
    required this.controller,
    this.sourceSetup,
  });
  final LegacyRemoteManagementController controller;
  final LegacyRemoteSourceSetupApi? sourceSetup;

  @override
  State<LegacyRemoteManagementScreen> createState() =>
      _LegacyRemoteManagementScreenState();
}

class _LegacyRemoteManagementScreenState
    extends State<LegacyRemoteManagementScreen> {
  AppInteractionController? _interaction;
  int _viewEpoch = 0;
  bool _showSourceSetup = false;

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

  void _setupSource() {
    if (widget.sourceSetup == null || !widget.controller.canAct) return;
    setState(() => _showSourceSetup = true);
  }

  void _cancelSourceSetup() {
    if (mounted) setState(() => _showSourceSetup = false);
  }

  void _sourceSaved() {
    if (!mounted) return;
    setState(() => _showSourceSetup = false);
    unawaited(widget.controller.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant LegacyRemoteManagementScreen oldWidget) {
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
    LegacyRemoteDevice device,
    LegacyRemoteCommandDefinition command,
  ) async {
    final epoch = _viewEpoch;
    await widget.controller.preview(device, command);
    if (!mounted ||
        epoch != _viewEpoch ||
        widget.controller.state !=
            LegacyRemoteManagementState.awaitingConfirmation) {
      return;
    }
    final preview = widget.controller.pendingPreview;
    if (preview == null ||
        preview.deviceId != device.deviceId ||
        preview.key != command.key) {
      return;
    }
    final strings = _RemoteStrings.of(context);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(strings.confirmTitle),
        content: Text(
          strings.confirmBody(strings.command(command.key), device.name),
        ),
        actions: [
          _DialogAction(
            key: const ValueKey('legacy-remote-cancel-action'),
            label: strings.cancel,
            onPressed: () {
              widget.controller.cancelPending();
              Navigator.of(dialogContext).pop();
            },
          ),
          _DialogAction(
            key: const ValueKey('legacy-remote-confirm-action'),
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

  Future<void> _learn(LegacyRemoteDevice device) async {
    final epoch = _viewEpoch;
    final strings = _RemoteStrings.of(context);
    final key = await showCupertinoModalPopup<LegacyRemoteCommandKey>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(strings.chooseKey),
        actions: [
          for (final value in LegacyRemoteCommandKey.values)
            CupertinoActionSheetAction(
              key: ValueKey(
                'legacy-remote-learn-${device.deviceId}-${value.name}',
              ),
              onPressed: () => Navigator.of(sheetContext).pop(value),
              child: Text(strings.command(value)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(strings.cancel),
        ),
      ),
    );
    if (!mounted || epoch != _viewEpoch || key == null) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(strings.learnTitle),
        content: Text(strings.learnBody(strings.command(key), device.name)),
        actions: [
          _DialogAction(
            key: const ValueKey('legacy-remote-learn-cancel-action'),
            label: strings.cancel,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          _DialogAction(
            key: const ValueKey('legacy-remote-learn-confirm-action'),
            label: strings.startLearning,
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (mounted && epoch == _viewEpoch) {
                widget.controller.learn(device, key);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = _RemoteStrings.of(context);
    final controller = widget.controller;
    final sourceSetup = widget.sourceSetup;
    if (_showSourceSetup && sourceSetup != null) {
      return _LegacyRemoteSourceSetupScreen(
        api: sourceSetup,
        onDone: _sourceSaved,
        onCancel: _cancelSourceSetup,
      );
    }
    return ServiceRootScaffold(
      title: strings.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(strings.safety),
            footer: Text(strings.safetyHint),
            children: [
              _LiveStatus(controller: controller, strings: strings),
              if (controller.state == LegacyRemoteManagementState.failed ||
                  controller.state == LegacyRemoteManagementState.stale)
                SettingsActionTile(
                  buttonKey: const ValueKey('legacy-remote-retry'),
                  title: Text(strings.retry),
                  leading: const Icon(CupertinoIcons.refresh),
                  onTap: controller.canAct ? controller.load : null,
                ),
            ],
          ),
        ),
        if (widget.sourceSetup != null)
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(strings.setupTitle),
              footer: Text(strings.setupHint),
              children: [
                SettingsActionTile(
                  buttonKey: const ValueKey('legacy-remote-add-source'),
                  title: Text(strings.setup),
                  leading: const Icon(CupertinoIcons.add_circled),
                  onTap: controller.canAct ? _setupSource : null,
                ),
              ],
            ),
          ),
        if (controller.devices.isNotEmpty)
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
                    for (final device in controller.devices)
                      SizedBox(
                        width: width,
                        child: _DeviceSection(
                          device: device,
                          strings: strings,
                          enabled: controller.canAct && device.canDispatch,
                          onCommand: _request,
                          onLearn: _learn,
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
  final LegacyRemoteManagementController controller;
  final _RemoteStrings strings;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (controller.state) {
      LegacyRemoteManagementState.idle || LegacyRemoteManagementState.loading =>
        (CupertinoIcons.hourglass, strings.loading),
      LegacyRemoteManagementState.failed => (
        CupertinoIcons.exclamationmark_triangle,
        strings.failed,
      ),
      LegacyRemoteManagementState.stale => (
        CupertinoIcons.lock_shield,
        strings.stale,
      ),
      LegacyRemoteManagementState.verified
          when controller.lastLearning != null =>
        (
          CupertinoIcons.checkmark_shield,
          '${strings.learned} ${strings.deviceUnverified}.',
        ),
      LegacyRemoteManagementState.verified => (
        CupertinoIcons.checkmark_circle,
        '${strings.delivered} ${strings.deviceUnverified}.',
      ),
      _ when controller.devices.isEmpty => (
        CupertinoIcons.rectangle_stack,
        strings.empty,
      ),
      _ => (CupertinoIcons.shield, strings.safetyHint),
    };
    return Semantics(
      key: const ValueKey('legacy-remote-live-status'),
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
              if (controller.state == LegacyRemoteManagementState.loading ||
                  controller.state == LegacyRemoteManagementState.busy)
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
    required this.onCommand,
    required this.onLearn,
  });
  final LegacyRemoteDevice device;
  final _RemoteStrings strings;
  final bool enabled;
  final void Function(LegacyRemoteDevice, LegacyRemoteCommandDefinition)
  onCommand;
  final void Function(LegacyRemoteDevice) onLearn;

  @override
  Widget build(BuildContext context) => SettingsSection(
    header: Text(device.name),
    children: [
      Semantics(
        key: ValueKey('legacy-remote-state-${device.deviceId}'),
        container: true,
        readOnly: true,
        label: strings.semantics(device),
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
                  icon: device.providerVerified
                      ? CupertinoIcons.checkmark_shield
                      : CupertinoIcons.shield_slash,
                  label: device.providerVerified
                      ? strings.providerVerified
                      : strings.providerUnverified,
                ),
                _Evidence(
                  icon: CupertinoIcons.question_circle,
                  label: strings.deviceUnverified,
                ),
              ],
            ),
          ),
        ),
      ),
      if (device.providerType == LegacyRemoteProvider.isolatedBridge)
        SettingsActionTile(
          buttonKey: ValueKey('legacy-remote-learn-${device.deviceId}'),
          title: Text(strings.learn),
          additionalInfo: Text(strings.deviceUnverified),
          leading: const Icon(CupertinoIcons.waveform_path),
          onTap: enabled ? () => onLearn(device) : null,
        ),
      for (final command in device.commands)
        SettingsActionTile(
          buttonKey: ValueKey(
            'legacy-remote-${device.deviceId}-${command.key.name}',
          ),
          title: Text(strings.command(command.key)),
          leading: Icon(_commandIcon(command.key)),
          onTap: enabled ? () => onCommand(device, command) : null,
        ),
    ],
  );
}

class _LegacyRemoteSourceSetupScreen extends StatefulWidget {
  const _LegacyRemoteSourceSetupScreen({
    required this.api,
    required this.onDone,
    required this.onCancel,
  });
  final LegacyRemoteSourceSetupApi api;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  @override
  State<_LegacyRemoteSourceSetupScreen> createState() =>
      _LegacyRemoteSourceSetupScreenState();
}

class _LegacyRemoteSourceSetupScreenState
    extends State<_LegacyRemoteSourceSetupScreen> {
  final _name = TextEditingController();
  final _entity = TextEditingController(text: 'remote.');
  final _device = TextEditingController();
  final _command = TextEditingController();
  List<LegacyRemoteSetupService> _services = const [];
  List<LegacyRemoteSourceBinding> _sources = const [];
  LegacyRemoteSetupService? _service;
  LegacyRemoteCommandKey _key = LegacyRemoteCommandKey.powerToggle;
  bool _loading = true;
  bool _saving = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait([
        widget.api.setupServices(),
        widget.api.listSources(),
      ]);
      if (!mounted) return;
      final services = values[0] as List<LegacyRemoteSetupService>;
      setState(() {
        _services = services;
        _sources = values[1] as List<LegacyRemoteSourceBinding>;
        _service = services.firstOrNull;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _chooseService(_RemoteStrings strings) async {
    if (_services.isEmpty || _saving) return;
    final selected = await showCupertinoModalPopup<LegacyRemoteSetupService>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(strings.service),
        actions: [
          for (final service in _services)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, service),
              child: Text(service.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
      ),
    );
    if (mounted && selected != null) setState(() => _service = selected);
  }

  Future<void> _chooseKey(_RemoteStrings strings) async {
    if (_saving) return;
    final selected = await showCupertinoModalPopup<LegacyRemoteCommandKey>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(strings.commandKey),
        actions: [
          for (final key in LegacyRemoteCommandKey.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, key),
              child: Text(strings.command(key)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
      ),
    );
    if (mounted && selected != null) setState(() => _key = selected);
  }

  Future<void> _save() async {
    final service = _service;
    if (_saving || service == null) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.api.configureSource(
        service: service,
        name: _name.text,
        entityId: _entity.text,
        learnedDeviceName: _device.text,
        commandKey: _key,
        learnedCommandName: _command.text,
      );
      if (mounted) widget.onDone();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _entity.dispose();
    _device.dispose();
    _command.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = _RemoteStrings.of(context);
    return ServiceRootScaffold(
      title: strings.setupTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(strings.setupTitle),
            footer: Text(strings.setupHint),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('legacy-remote-source-cancel'),
                title: Text(strings.cancel),
                leading: const Icon(CupertinoIcons.chevron_back),
                onTap: _saving ? null : widget.onCancel,
              ),
              if (_loading)
                const SizedBox(
                  height: 56,
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else ...[
                SettingsActionTile(
                  buttonKey: const ValueKey('legacy-remote-source-service'),
                  title: Text(strings.service),
                  additionalInfo: Text(_service?.name ?? strings.noService),
                  leading: const Icon(CupertinoIcons.home),
                  onTap: _services.isEmpty
                      ? null
                      : () => _chooseService(strings),
                ),
                _SourceField(
                  key: const ValueKey('legacy-remote-source-name'),
                  controller: _name,
                  placeholder: strings.sourceName,
                ),
                _SourceField(
                  key: const ValueKey('legacy-remote-source-entity'),
                  controller: _entity,
                  placeholder: strings.entityId,
                ),
                _SourceField(
                  key: const ValueKey('legacy-remote-source-device'),
                  controller: _device,
                  placeholder: strings.learnedDevice,
                ),
                SettingsActionTile(
                  buttonKey: const ValueKey('legacy-remote-source-key'),
                  title: Text(strings.commandKey),
                  additionalInfo: Text(strings.command(_key)),
                  leading: const Icon(CupertinoIcons.square_grid_2x2),
                  onTap: () => _chooseKey(strings),
                ),
                _SourceField(
                  key: const ValueKey('legacy-remote-source-command'),
                  controller: _command,
                  placeholder: strings.learnedCommand,
                ),
                SettingsActionTile(
                  buttonKey: const ValueKey('legacy-remote-source-save'),
                  title: Text(strings.save),
                  leading: const Icon(CupertinoIcons.checkmark_shield),
                  onTap: _saving || _service == null ? null : _save,
                ),
                if (_failed)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(strings.setupFailed),
                  ),
              ],
            ],
          ),
        ),
        if (_sources.isNotEmpty)
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(strings.savedSources),
              children: [
                for (final source in _sources)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('${source.name} · ${source.entityId}'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SourceField extends StatelessWidget {
  const _SourceField({
    super.key,
    required this.controller,
    required this.placeholder,
  });
  final TextEditingController controller;
  final String placeholder;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      enabled: true,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 128,
      clearButtonMode: OverlayVisibilityMode.editing,
    ),
  );
}

IconData _commandIcon(LegacyRemoteCommandKey key) => switch (key) {
  LegacyRemoteCommandKey.powerToggle ||
  LegacyRemoteCommandKey.powerOn ||
  LegacyRemoteCommandKey.powerOff => CupertinoIcons.power,
  LegacyRemoteCommandKey.volumeUp => CupertinoIcons.speaker_2_fill,
  LegacyRemoteCommandKey.volumeDown => CupertinoIcons.speaker_1_fill,
  LegacyRemoteCommandKey.mute => CupertinoIcons.speaker_slash_fill,
  LegacyRemoteCommandKey.play => CupertinoIcons.play_fill,
  LegacyRemoteCommandKey.pause => CupertinoIcons.pause_fill,
  LegacyRemoteCommandKey.stop => CupertinoIcons.stop_fill,
  LegacyRemoteCommandKey.up => CupertinoIcons.chevron_up,
  LegacyRemoteCommandKey.down => CupertinoIcons.chevron_down,
  LegacyRemoteCommandKey.left => CupertinoIcons.chevron_left,
  LegacyRemoteCommandKey.right => CupertinoIcons.chevron_right,
  _ => CupertinoIcons.circle_grid_3x3_fill,
};

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
