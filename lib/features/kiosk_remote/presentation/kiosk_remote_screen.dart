import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/kiosk_remote_controller.dart';
import '../domain/kiosk_remote_models.dart';
import '../runtime/mqtt_local_broker.dart';

class KioskRemoteScreen extends StatefulWidget {
  const KioskRemoteScreen({
    super.key,
    required this.controller,
    this.brokerSettings,
    this.brokerSettingsLoading = false,
    this.brokerSettingsFailed = false,
    this.onSaveBrokerSettings,
  });
  final KioskRemoteController controller;
  final LocalMqttBrokerSettings? brokerSettings;
  final bool brokerSettingsLoading, brokerSettingsFailed;
  final Future<void> Function(LocalMqttBrokerSettings settings)?
  onSaveBrokerSettings;
  @override
  State<KioskRemoteScreen> createState() => _KioskRemoteScreenState();
}

class _KioskRemoteScreenState extends State<KioskRemoteScreen> {
  final _scopes = <String>{'read'};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.snapshot == null) {
        widget.controller.load();
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return ServiceRootScaffold(
      title: l10n.kioskRemoteTitle,
      slivers: [
        if (widget.brokerSettings != null &&
            widget.onSaveBrokerSettings != null)
          SliverToBoxAdapter(
            child: MqttBrokerSettingsEditor(
              settings: widget.brokerSettings!,
              loading: widget.brokerSettingsLoading,
              loadFailed: widget.brokerSettingsFailed,
              onSave: widget.onSaveBrokerSettings!,
            ),
          ),
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.kioskRemoteStatus),
            footer: Text(l10n.kioskRemoteNoListener),
            children: [
              _Status(controller: controller),
              SettingsActionTile(
                buttonKey: const ValueKey('kiosk-remote-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: controller.busy ? null : controller.load,
              ),
            ],
          ),
        ),
        if (controller.oneTimeToken case final token?)
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(l10n.kioskRemoteOneTimeSecret),
              footer: Text(l10n.kioskRemoteSecretHint),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Semantics(
                    label: l10n.kioskRemoteOneTimeSecret,
                    child: Text(token, maxLines: 3),
                  ),
                ),
                SettingsActionTile(
                  buttonKey: const ValueKey('kiosk-remote-copy'),
                  leading: const Icon(CupertinoIcons.doc_on_clipboard),
                  title: Text(l10n.kioskRemoteCopySecret),
                  onTap: () => Clipboard.setData(ClipboardData(text: token)),
                ),
                if (controller.canEnrollCreatedPairing)
                  SettingsActionTile(
                    buttonKey: const ValueKey('kiosk-remote-enroll'),
                    leading: const Icon(CupertinoIcons.lock_shield),
                    title: Text(l10n.kioskRemoteUseOnTablet),
                    additionalInfo: Text(l10n.kioskRemoteUseOnTabletHint),
                    onTap: controller.busy
                        ? null
                        : controller.enrollCreatedPairing,
                  ),
              ],
            ),
          ),
        if (controller.enrolledPairingId != null)
          SliverToBoxAdapter(
            child: Semantics(
              liveRegion: true,
              label: l10n.kioskRemoteEnrollmentSaved,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(l10n.kioskRemoteEnrollmentSaved),
              ),
            ),
          ),
        if (snapshot != null) ...[
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(l10n.kioskRemoteScopes),
              footer: Text(l10n.kioskRemoteScopesHint),
              children: [
                _ScopeSwitch(
                  label: l10n.kioskRemoteReadScope,
                  value: _scopes.contains('read'),
                  onChanged: null,
                ),
                _ScopeSwitch(
                  label: l10n.kioskRemoteControlScope,
                  value: _scopes.contains('control'),
                  onChanged: controller.busy
                      ? null
                      : (value) => setState(() {
                          value
                              ? _scopes.add('control')
                              : _scopes.remove('control');
                        }),
                ),
                _ScopeSwitch(
                  label: l10n.kioskRemoteAdminScope,
                  value: _scopes.contains('admin'),
                  onChanged: controller.busy
                      ? null
                      : (value) => setState(() {
                          value
                              ? _scopes.add('admin')
                              : _scopes.remove('admin');
                        }),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(l10n.kioskRemoteDevices),
              footer: Text(l10n.kioskRemoteCreateHint),
              children: [
                if (snapshot.devices
                    .where((item) => item.state == 'active')
                    .isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.kioskRemoteNoDevices),
                  )
                else
                  for (final device in snapshot.devices.where(
                    (item) => item.state == 'active',
                  ))
                    SettingsActionTile(
                      buttonKey: ValueKey('kiosk-remote-pair-${device.id}'),
                      leading: const Icon(CupertinoIcons.device_phone_portrait),
                      title: Text(device.name),
                      additionalInfo: Text(l10n.kioskRemotePairDevice),
                      onTap: controller.busy
                          ? null
                          : () => controller.create(device, Set.of(_scopes)),
                    ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(l10n.kioskRemotePairings),
              footer: Text(l10n.kioskRemotePairingHint),
              children: [
                if (snapshot.pairings.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.kioskRemoteEmpty),
                  )
                else
                  for (final pairing in snapshot.pairings)
                    _PairingTile(
                      pairing: pairing,
                      busy: controller.busy,
                      onRevoke: () => controller.revoke(pairing),
                    ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class MqttBrokerSettingsEditor extends StatefulWidget {
  const MqttBrokerSettingsEditor({
    super.key,
    required this.settings,
    required this.onSave,
    this.loading = false,
    this.loadFailed = false,
  });

  final LocalMqttBrokerSettings settings;
  final Future<void> Function(LocalMqttBrokerSettings settings) onSave;
  final bool loading, loadFailed;

  @override
  State<MqttBrokerSettingsEditor> createState() =>
      _MqttBrokerSettingsEditorState();
}

class _MqttBrokerSettingsEditorState extends State<MqttBrokerSettingsEditor> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late bool _enabled;
  bool _saving = false, _saved = false, _invalid = false, _saveFailed = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.settings.host);
    _port = TextEditingController(text: '${widget.settings.port}');
    _enabled = widget.settings.enabled;
  }

  @override
  void didUpdateWidget(covariant MqttBrokerSettingsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings == widget.settings || _saving) return;
    _host.text = widget.settings.host;
    _port.text = '${widget.settings.port}';
    _enabled = widget.settings.enabled;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    LocalMqttBrokerSettings next;
    try {
      next = LocalMqttBrokerSettings(
        enabled: _enabled,
        host: _host.text,
        port: int.parse(_port.text),
        tls: true,
      );
    } catch (_) {
      setState(() {
        _invalid = true;
        _saved = _saveFailed = false;
      });
      return;
    }
    setState(() {
      _saving = true;
      _invalid = _saved = _saveFailed = false;
    });
    try {
      await widget.onSave(next);
      if (!mounted) return;
      setState(() => _saved = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = widget.loadFailed
        ? l10n.kioskRemoteBrokerLoadFailed
        : _invalid
        ? l10n.kioskRemoteBrokerInvalid
        : _saveFailed
        ? l10n.kioskRemoteBrokerSaveFailed
        : _saved
        ? l10n.kioskRemoteBrokerSaved
        : null;
    return SettingsSection(
      header: Text(l10n.kioskRemoteBrokerTitle),
      footer: Text(l10n.kioskRemoteBrokerHint),
      children: [
        CupertinoListTile(
          title: Text(l10n.kioskRemoteBrokerEnabled),
          trailing: Semantics(
            label: l10n.kioskRemoteBrokerEnabled,
            toggled: _enabled,
            child: CupertinoSwitch(
              key: const ValueKey('mqtt-broker-enabled'),
              value: _enabled,
              onChanged: _saving || widget.loading
                  ? null
                  : (value) => setState(() {
                      _enabled = value;
                      _saved = _invalid = _saveFailed = false;
                    }),
            ),
          ),
        ),
        CupertinoListTile(
          title: Text(l10n.kioskRemoteBrokerHost),
          subtitle: Semantics(
            label: l10n.kioskRemoteBrokerHost,
            textField: true,
            child: CupertinoTextField(
              key: const ValueKey('mqtt-broker-host'),
              controller: _host,
              enabled: !_saving && !widget.loading,
              placeholder: 'mqtt.home.arpa',
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {
                _saved = _invalid = _saveFailed = false;
              }),
            ),
          ),
        ),
        CupertinoListTile(
          title: Text(l10n.kioskRemoteBrokerPort),
          subtitle: Semantics(
            label: l10n.kioskRemoteBrokerPort,
            textField: true,
            child: CupertinoTextField(
              key: const ValueKey('mqtt-broker-port'),
              controller: _port,
              enabled: !_saving && !widget.loading,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_saving && !widget.loading) _save();
              },
              onChanged: (_) => setState(() {
                _saved = _invalid = _saveFailed = false;
              }),
            ),
          ),
        ),
        const CupertinoListTile(
          title: Text('TLS'),
          trailing: Icon(CupertinoIcons.lock_shield_fill),
        ),
        if (status != null)
          Semantics(
            liveRegion: true,
            label: status,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(status),
            ),
          ),
        CupertinoButton(
          key: const ValueKey('mqtt-broker-save'),
          minimumSize: const Size(double.infinity, 48),
          onPressed: _saving || widget.loading ? null : _save,
          child: _saving
              ? const CupertinoActivityIndicator()
              : Text(l10n.commonSave),
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller});
  final KioskRemoteController controller;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (controller.state) {
      KioskRemoteViewState.idle ||
      KioskRemoteViewState.loading => l10n.kioskRemoteLoading,
      KioskRemoteViewState.ready => l10n.kioskRemoteReady,
      KioskRemoteViewState.failed => l10n.kioskRemoteFailed,
      KioskRemoteViewState.stale => l10n.kioskRemoteStale,
    };
    return Semantics(
      liveRegion: true,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (controller.busy) ...[
                const CupertinoActivityIndicator(),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopeSwitch extends StatelessWidget {
  const _ScopeSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => CupertinoListTile(
    title: Text(label),
    trailing: Semantics(
      label: label,
      toggled: value,
      child: CupertinoSwitch(value: value, onChanged: onChanged),
    ),
  );
}

class _PairingTile extends StatelessWidget {
  const _PairingTile({
    required this.pairing,
    required this.busy,
    required this.onRevoke,
  });
  final KioskRemotePairing pairing;
  final bool busy;
  final VoidCallback onRevoke;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pairing.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(l10n.kioskRemoteScopeList(pairing.scopes.join(', '))),
                Text(pairing.mqttTopicPrefix),
                Text(
                  pairing.state == 'active'
                      ? l10n.kioskRemoteActive
                      : l10n.kioskRemoteRevoked,
                ),
              ],
            ),
          ),
          CupertinoButton(
            key: const ValueKey('remote-pairing-revoke'),
            minimumSize: const Size(48, 48),
            onPressed: busy ? null : onRevoke,
            child: Text(l10n.kioskRemoteRevoke),
          ),
        ],
      ),
    );
  }
}
