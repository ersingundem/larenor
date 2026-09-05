import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_guest.dart';
import '../providers/proxmox_providers.dart';
import 'console/proxmox_console_screen.dart';
import 'widgets/proxmox_field_label.dart';
import 'widgets/proxmox_usage_bar.dart';
import '../../../shared/widgets/settings_section.dart';
import 'proxmox_session_guard.dart';
import 'proxmox_mutation_support.dart';

/// Config keys treated as "common" and given friendly labels; everything
/// else in the guest's config is still shown and editable, just under an
/// "Advanced" section with its raw key as the label.
const _nameKeysByType = {
  ProxmoxGuestType.qemu: 'name',
  ProxmoxGuestType.lxc: 'hostname',
};
const _commonKeys = ['cores', 'memory'];

class ProxmoxGuestDetailScreen extends ConsumerStatefulWidget {
  const ProxmoxGuestDetailScreen({
    super.key,
    required this.guest,
    this.sourceCurrent,
  });

  final ProxmoxGuest guest;
  final bool Function()? sourceCurrent;

  @override
  ConsumerState<ProxmoxGuestDetailScreen> createState() =>
      _ProxmoxGuestDetailScreenState();
}

class _ProxmoxGuestDetailScreenState
    extends ProxmoxSessionState<ProxmoxGuestDetailScreen> {
  final Map<String, TextEditingController> _controllers = {};
  bool _onboot = false;
  bool _saving = false;
  bool _openingConsole = false;
  bool _needsReview = false;
  Route<dynamic>? _modal;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;
  bool get _available =>
      sessionAvailable && widget.sourceCurrent?.call() != false;
  bool _current(ProxmoxSessionLease lease) =>
      _available && isSessionCurrent(lease);

  @override
  void onSessionInvalidated() {
    _loadedConfig = null;
    _onboot = false;
    for (final controller in _controllers.values) {
      controller.clear();
    }
    if (_saving) _needsReview = true;
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void didUpdateWidget(ProxmoxGuestDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!sameProxmoxGuest(oldWidget.guest, widget.guest)) {
      sessionGeneration++;
      onSessionInvalidated();
    }
  }

  String? _error;
  Map<String, dynamic>? _loadedConfig;

  String get _nameKey => _nameKeysByType[widget.guest.type]!;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _seedControllers(Map<String, dynamic> config) {
    if (_loadedConfig != null) return;
    _loadedConfig = {
      for (final entry in config.entries)
        if (!_credentialKey(entry.key)) entry.key: entry.value,
    };
    for (final entry in _loadedConfig!.entries) {
      if (entry.key == 'onboot') {
        _onboot = '${entry.value}' == '1';
        continue;
      }
      if (proxmoxHiddenConfigKeys.contains(entry.key)) continue;
      _controllers.putIfAbsent(entry.key, () => TextEditingController()).text =
          '${entry.value}';
    }
    for (final key in [_nameKey, ..._commonKeys]) {
      _controllers.putIfAbsent(key, () => TextEditingController());
    }
  }

  Future<void> _save(ProxmoxSessionLease lease) async {
    if (_saving ||
        _openingConsole ||
        _needsReview ||
        !_current(lease) ||
        _loadedConfig == null) {
      return;
    }
    final guest = widget.guest;
    final l10n = AppLocalizations.of(context);
    final changes = <String, String>{
      for (final entry in _controllers.entries)
        if (!_credentialKey(entry.key) &&
            entry.key != 'unprivileged' &&
            entry.value.text != '${_loadedConfig?[entry.key] ?? ''}')
          entry.key: entry.value.text,
      if (_onboot != ('${_loadedConfig?['onboot']}' == '1'))
        'onboot': _onboot ? '1' : '0',
    };
    if (changes.isEmpty) {
      if (mounted) closeProxmoxModal(context);
      return;
    }
    final digest = _loadedConfig?['digest'];
    if (digest is String) changes['digest'] = digest;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await lease.client.updateGuestConfig(
        guest.node,
        guest.type,
        guest.vmid,
        changes,
      );
      if (!_current(lease) || !sameProxmoxGuest(guest, widget.guest)) {
        _needsReview = true;
        return;
      }
      ref.invalidate(
        proxmoxGuestConfigProvider(guest.node, guest.type, guest.vmid),
      );
      ref.invalidate(proxmoxGuestsProvider(guest.node));
      if (mounted) closeProxmoxModal(context);
    } catch (error) {
      if (proxmoxMutationMayHaveRun(error)) _needsReview = true;
      if (_current(lease)) {
        setState(() => _error = proxmoxMutationFailureLabel(l10n, error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openConsole(ProxmoxSessionLease lease) async {
    if (_saving || _openingConsole || !_current(lease)) return;
    final guest = widget.guest;
    setState(() => _openingConsole = true);
    final sourceCurrent = captureProxmoxRouteSource(ref);
    if (sourceCurrent == null) {
      setState(() => _openingConsole = false);
      return;
    }
    final upstreamCurrent = widget.sourceCurrent;
    final route = CupertinoPageRoute<void>(
      builder: (_) => ProxmoxConsoleScreen(
        guest: guest,
        sourceCurrent: () =>
            sourceCurrent() && upstreamCurrent?.call() != false,
      ),
    );
    _modal = route;
    try {
      await Navigator.of(context).push<void>(route);
    } finally {
      if (identical(_modal, route)) _modal = null;
      if (mounted) setState(() => _openingConsole = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    final guest = widget.guest;
    final configAsync = _available
        ? ref.watch(
            proxmoxGuestConfigProvider(guest.node, guest.type, guest.vmid),
          )
        : null;
    final lease = captureSession();
    final enabled =
        _available &&
        lease != null &&
        !_saving &&
        !_openingConsole &&
        !_needsReview;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(guest.name)),
      child: SafeArea(
        child: !_available
            ? Center(
                child: Text(AppLocalizations.of(context).proxmoxSessionExpired),
              )
            : configAsync!.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                skipError: false,
                loading: () =>
                    const Center(child: CupertinoActivityIndicator()),
                error: (error, _) => Center(
                  child: Text(AppLocalizations.of(context).healthReadError),
                ),
                data: (config) {
                  _seedControllers(config);
                  final commonKeys = [_nameKey, ..._commonKeys];
                  final advancedKeys = config.keys.where(
                    (k) =>
                        !commonKeys.contains(k) &&
                        k != 'onboot' &&
                        !proxmoxHiddenConfigKeys.contains(k) &&
                        !_credentialKey(k),
                  );

                  return ListView(
                    children: [
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: ProxmoxUsageBar(
                                label: 'CPU',
                                fraction: guest.cpuFraction,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ProxmoxUsageBar(
                                label: 'RAM',
                                fraction: guest.memFraction,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SettingsSection(
                        header: Text(
                          AppLocalizations.of(context).moreInfoDetailsHeader,
                        ),
                        children: [
                          for (final key in commonKeys)
                            CupertinoTextFormFieldRow(
                              controller: _controllers[key],
                              readOnly: !enabled,
                              keyboardType: _commonKeys.contains(key)
                                  ? TextInputType.number
                                  : TextInputType.text,
                              prefix: proxmoxFormLabel(
                                context,
                                proxmoxFieldLabel(
                                  AppLocalizations.of(context),
                                  key,
                                ),
                              ),
                            ),
                          CupertinoListTile(
                            title: Text(
                              AppLocalizations.of(context).proxmoxStartOnBoot,
                            ),
                            trailing: CupertinoSwitch(
                              value: _onboot,
                              onChanged: enabled
                                  ? (value) {
                                      if (_current(lease)) {
                                        setState(() => _onboot = value);
                                      }
                                    }
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      if (advancedKeys.isNotEmpty)
                        SettingsSection(
                          header: Text(
                            AppLocalizations.of(context).proxmoxAdvancedHeader,
                          ),
                          footer: Text(
                            AppLocalizations.of(context).proxmoxAdvancedFooter,
                          ),
                          children: [
                            for (final key in advancedKeys)
                              CupertinoTextFormFieldRow(
                                controller: _controllers[key],
                                readOnly: !enabled || key == 'unprivileged',
                                prefix: proxmoxFormLabel(
                                  context,
                                  proxmoxFieldLabel(
                                    AppLocalizations.of(context),
                                    key,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      SettingsSection(
                        header: Text(
                          AppLocalizations.of(context).proxmoxConsoleHeader,
                        ),
                        children: [
                          CupertinoListTile(
                            leading: const Icon(CupertinoIcons.desktopcomputer),
                            title: Text(
                              AppLocalizations.of(context).proxmoxOpenConsole,
                            ),
                            trailing: const CupertinoListTileChevron(),
                            onTap:
                                enabled && guest.isRunning && !guest.isTemplate
                                ? () => _openConsole(lease)
                                : null,
                          ),
                        ],
                      ),
                      if (_error != null || _needsReview)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            _needsReview
                                ? AppLocalizations.of(context)
                                      .proxmoxActionUnknown
                                : _error!,
                            style: TextStyle(
                              color: CupertinoColors.systemRed.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: CupertinoButton.filled(
                          onPressed: enabled ? () => _save(lease) : null,
                          child: _saving
                              ? const CupertinoActivityIndicator(
                                  color: CupertinoColors.white,
                                )
                              : Text(AppLocalizations.of(context).commonSave),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

// Credential edits need a deliberate obscured/empty field workflow. Never seed
// these returned values into the general advanced editor.
bool _credentialKey(String key) => const {
  'cipassword',
  'password',
  'passwd',
  'token',
  'secret',
  'api_token',
  'apikey',
  'api_key',
  'ssh_private_key',
}.contains(key.toLowerCase());
