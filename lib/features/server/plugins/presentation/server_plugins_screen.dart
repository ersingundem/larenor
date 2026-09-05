import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_plugins_controller.dart';
import '../domain/server_plugin_models.dart';
import '../../services/presentation/server_services_screen.dart';

/// Reached through the Settings PIN gate and a signed-in administrator account.
class ServerPluginsScreen extends ConsumerStatefulWidget {
  const ServerPluginsScreen({super.key});
  @override
  ConsumerState<ServerPluginsScreen> createState() =>
      _ServerPluginsScreenState();
}

class _ServerPluginsScreenState extends MediaSessionState<ServerPluginsScreen> {
  late final ServerAccountController _account;
  late final ServerPluginsController _plugins;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  Route<Object?>? _dialog;
  VoidCallback? _clearDraft;
  bool _visible = true, _expired = false, _loaded = false, _pinReady = false;
  bool _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);
  bool get _enabled =>
      _active &&
      !_plugins.busy &&
      !_plugins.needsRefresh &&
      _plugins.failure == null;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _plugins = ServerPluginsController(_account);
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.working ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current && _dialog == null) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted) return;
    final wasBusy = _plugins.busy;
    _expired = true;
    sessionGeneration++;
    final clear = _clearDraft;
    _clearDraft = null;
    final route = _dialog;
    _dialog = null;
    void retire() {
      if (!mounted) return;
      if (route?.isActive == true) {
        clear?.call();
        route!.navigator?.removeRoute(route);
      }
      _plugins.invalidate();
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
    // Expire a token rotation awaited by this screen, without cancelling a
    // different page's account form or issuing a remote logout.
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    _clearDraft = null;
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _plugins.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  VoidCallback _callback(VoidCallback action) {
    final current = _capture();
    return () {
      if (current()) action();
    };
  }

  Future<void> _load() async {
    if (!_active || _plugins.busy || _dialog != null) return;
    await _plugins.load(current: _capture());
  }

  Future<T?> _show<T>(
    Widget Function(BuildContext, bool Function()) builder,
  ) async {
    if (!_enabled || _dialog != null) return null;
    final current = _capture();
    late final CupertinoDialogRoute<T> route;
    route = CupertinoDialogRoute<T>(
      context: context,
      builder: (context) {
        if (ModalRoute.isCurrentOf(context) != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(_dialog, route) && !route.isCurrent) {
              _expire();
            }
          });
        }
        return builder(
          context,
          () => current() && identical(_dialog, route) && route.isCurrent,
        );
      },
    );
    _dialog = route;
    final result = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    _clearDraft = null;
    return current() ? result : null;
  }

  Future<void> _review(PluginCatalogEntry entry) async {
    if (entry.manifest.integrationRole == 'internal_engine') return;
    final current = _capture();
    final draft = await _show<_PluginDraft>(
      (context, valid) => _PluginForm(
        entry: entry,
        current: valid,
        registerClear: (clear) => _clearDraft = clear,
      ),
    );
    if (draft == null || !current()) return;
    await _plugins.review(
      entry,
      platform: draft.platform,
      settings: draft.settings,
      current: current,
    );
    if (!current()) return;
    final preview = _plugins.preview;
    if (preview != null) {
      await _show<void>(
        (context, valid) => _PreviewView(
          preview: preview,
          name: entry.manifest.displayName,
          current: valid,
        ),
      );
    }
    if (mounted) _plugins.clearPreview();
  }

  void _connect() {
    if (!_enabled || _dialog != null) return;
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute<void>(builder: (_) => const ServerServicesScreen()),
    );
  }

  String _failure(AppLocalizations l10n) => switch (_plugins.failure) {
    'unauthorized' => l10n.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l10n.serverFailurePermission,
    'invalid_request' => l10n.serverPluginsIncomplete,
    'rate_limited' => l10n.serverFailureRateLimit,
    _ =>
      _plugins.needsRefresh
          ? l10n.serverPluginsReviewUnavailable
          : l10n.serverFailureConnection,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) unawaited(_load());
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.serverPluginsTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _plugins,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l10n.serverOpenFromSettings
                        : l10n.serverFailurePermission,
                  ),
                ),
              );
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(l10n.serverPluginsIntro),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        children: [
                          CupertinoButton(
                            key: const ValueKey('plugins-refresh'),
                            onPressed: _active && !_plugins.busy
                                ? _callback(_load)
                                : null,
                            child: Text(l10n.commonRefresh),
                          ),
                          CupertinoButton(
                            key: const ValueKey('plugins-connect'),
                            onPressed: _enabled ? _callback(_connect) : null,
                            child: Text(l10n.serverPluginsConnectExisting),
                          ),
                        ],
                      ),
                    ),
                    if (_plugins.busy)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_plugins.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_failure(l10n)),
                        ),
                      ),
                    if (_plugins.catalog != null) ...[
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(l10n.serverPluginsWorkerUnavailable),
                      ),
                      for (final entry in _plugins.catalog!.entries)
                        _card(l10n, entry),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _card(AppLocalizations l10n, PluginCatalogEntry entry) {
    final manifest = entry.manifest;
    return SettingsSection(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(manifest.displayName, style: AppText.headline),
              if (manifest.integrationRole == 'internal_engine')
                Text(l10n.serverPluginsIntegratedMusic, style: AppText.subhead),
              const SizedBox(height: 8),
              Text('${l10n.serverPluginsVersion}: ${manifest.version}'),
              Text('${l10n.serverPluginsLicense}: ${manifest.license}'),
              Text(
                '${l10n.serverPluginsPlatforms}: ${manifest.images.map((image) => image.platform).join(', ')}',
              ),
              const SizedBox(height: 8),
              Text(l10n.serverPluginsUnavailable, style: AppText.subhead),
              Text(l10n.serverPluginsImageUnverified, style: AppText.footnote),
              if (manifest.integrationRole != 'internal_engine')
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: CupertinoButton(
                    key: ValueKey('plugin-review-${manifest.serviceId}'),
                    onPressed: _enabled
                        ? _callback(() => _review(entry))
                        : null,
                    child: Text(l10n.serverPluginsPreview),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PluginDraft {
  const _PluginDraft(this.platform, this.settings);
  final String platform;
  final Map<String, Object?> settings;
}

String _settingLabel(AppLocalizations l10n, String name) => switch (name) {
  'instanceName' => l10n.serverPluginsSettingInstanceName,
  'dataRootId' => l10n.serverPluginsSettingDataRootId,
  'libraryRootId' => l10n.serverPluginsSettingLibraryRootId,
  'mediaRootId' => l10n.serverPluginsSettingMediaRootId,
  'musicRootId' => l10n.serverPluginsSettingMusicRootId,
  'torrentPort' => l10n.serverPluginsSettingTorrentPort,
  _ => l10n.serverPluginsSettingWebPort,
};

class _PluginForm extends StatefulWidget {
  const _PluginForm({
    required this.entry,
    required this.current,
    required this.registerClear,
  });
  final PluginCatalogEntry entry;
  final bool Function() current;
  final void Function(VoidCallback) registerClear;
  @override
  State<_PluginForm> createState() => _PluginFormState();
}

class _PluginFormState extends State<_PluginForm> {
  final _fields = <String, TextEditingController>{};
  String? _platform;
  bool _invalid = false, _submitted = false;

  @override
  void initState() {
    super.initState();
    for (final spec in widget.entry.manifest.settings) {
      _fields[spec.name] = TextEditingController(
        text: spec.defaultValue?.toString() ?? '',
      );
    }
    // Without a worker report the Client cannot infer the Server's platform.
    widget.registerClear(_clear);
  }

  void _clear() {
    if (!mounted) return;
    for (final field in _fields.values) {
      field.clear();
    }
    _platform = null;
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_submitted || !widget.current()) return;
    final manifest = widget.entry.manifest;
    final values = {
      for (final spec in manifest.settings)
        spec.name: spec.parseInput(_fields[spec.name]!.text),
    };
    if (_platform == null || !manifest.acceptsSettings(values)) {
      setState(() => _invalid = true);
      return;
    }
    final draft = _PluginDraft(_platform!, Map.unmodifiable(values));
    _submitted = true;
    _clear();
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _DialogPanel(
      title:
          '${widget.entry.manifest.displayName} · ${l10n.serverPluginsSettings}',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.serverPluginsPreviewHint),
          const SizedBox(height: 16),
          Text(l10n.serverPluginsPlatformChoice, style: AppText.subhead),
          Wrap(
            children: [
              for (final image in widget.entry.manifest.images)
                Semantics(
                  selected: _platform == image.platform,
                  child: CupertinoButton(
                    key: ValueKey('plugin-platform-${image.platform}'),
                    onPressed: () {
                      if (widget.current()) {
                        setState(() => _platform = image.platform);
                      }
                    },
                    child: Text(
                      '${_platform == image.platform ? '✓ ' : ''}${image.platform}',
                    ),
                  ),
                ),
            ],
          ),
          for (final spec in widget.entry.manifest.settings)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_settingLabel(l10n, spec.name), style: AppText.subhead),
                  const SizedBox(height: 6),
                  CupertinoTextField(
                    key: ValueKey('plugin-setting-${spec.name}'),
                    controller: _fields[spec.name],
                    enabled: !_submitted && widget.current(),
                    placeholder: _settingLabel(l10n, spec.name),
                    keyboardType: spec.kind == PluginSettingKind.port
                        ? TextInputType.number
                        : TextInputType.text,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: spec.kind == PluginSettingKind.port
                        ? 5
                        : spec.kind == PluginSettingKind.slug
                        ? 40
                        : 32,
                    textInputAction: TextInputAction.next,
                    padding: const EdgeInsets.all(12),
                  ),
                ],
              ),
            ),
          Text(l10n.serverPluginsRootHint, style: AppText.footnote),
          if (_invalid)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(l10n.serverPluginsIncomplete),
              ),
            ),
        ],
      ),
      actions: [
        CupertinoButton(
          onPressed: () {
            if (widget.current() && !_submitted) {
              _clear();
              Navigator.pop(context);
            }
          },
          child: Text(l10n.commonCancel),
        ),
        CupertinoButton(
          key: const ValueKey('plugin-preview-submit'),
          onPressed: _submit,
          child: Text(l10n.serverPluginsPreview),
        ),
      ],
    );
  }
}

class _DialogPanel extends StatelessWidget {
  const _DialogPanel({
    required this.title,
    required this.content,
    required this.actions,
  });
  final String title;
  final Widget content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: CupertinoPopupSurface(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(title, style: AppText.headline),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: content,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(alignment: WrapAlignment.end, children: actions),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PreviewView extends StatefulWidget {
  const _PreviewView({
    required this.preview,
    required this.name,
    required this.current,
  });
  final ServerPluginPreview preview;
  final String name;
  final bool Function() current;
  @override
  State<_PreviewView> createState() => _PreviewViewState();
}

class _PreviewViewState extends State<_PreviewView> {
  Timer? _expiry;
  bool _expired = false;
  @override
  void initState() {
    super.initState();
    final delay = widget.preview.expiresAt.difference(DateTime.now().toUtc());
    _expired = delay <= Duration.zero;
    if (!_expired) {
      _expiry = Timer(delay, () {
        if (mounted) setState(() => _expired = true);
      });
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final plan = widget.preview.plan;
    final effects = plan.effects;
    Widget line(String label, Object value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text('$label: $value'),
    );
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(label, style: AppText.headline),
    );
    return _DialogPanel(
      title: '${widget.name} · ${l10n.serverPluginsPreviewTitle}',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.serverPluginsPreviewHint),
          const SizedBox(height: 12),
          Text(l10n.serverPluginsUnavailable, style: AppText.headline),
          if (_expired || widget.preview.expired(DateTime.now()))
            Semantics(
              liveRegion: true,
              child: Text(l10n.serverPluginsPreviewExpired),
            )
          else
            line(
              l10n.serverPluginsExpires,
              DateFormat.yMd(l10n.localeName)
                  .add_Hm()
                  .format(widget.preview.expiresAt.toLocal()),
            ),
          heading(l10n.serverPluginsReasons),
          Text(l10n.serverPluginsWorkerUnavailable),
          Text(l10n.serverPluginsImageUnverified),
          Text(l10n.serverPluginsHostPreflightRequired),
          heading(l10n.serverPluginsEffects),
          line(l10n.serverPluginsSettingInstanceName, plan.instanceName),
          line(l10n.serverPluginsPlatformChoice, plan.image.platform),
          heading(l10n.serverPluginsNetwork),
          Text(
            effects.network.mode == 'host'
                ? l10n.serverPluginsNetworkHost
                : l10n.serverPluginsNetworkBridge,
          ),
          if (effects.ports.isNotEmpty) ...[
            Text(l10n.serverPluginsPorts, style: AppText.subhead),
            for (final port in effects.ports)
              Text(
                '${port.protocol.toUpperCase()} ${port.hostPort} → ${port.containerPort}',
              ),
          ],
          if (effects.network.mode == 'host')
            for (final listener in effects.network.listeners)
              Text('${listener.protocol.toUpperCase()} ${listener.port}'),
          heading(l10n.serverPluginsStorage),
          Text(l10n.serverPluginsRootHint, style: AppText.footnote),
          for (final mount in effects.mounts)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${mount.rootId}${mount.relativePath.isEmpty ? '' : ' / ${mount.relativePath}'} → ${mount.target}\n${mount.readOnly ? l10n.serverPluginsReadOnly : l10n.serverPluginsWritable}',
              ),
            ),
          heading(l10n.serverPluginsResources),
          line(l10n.serverPluginsMemory, effects.resources.memoryMiB),
          line(l10n.serverPluginsCpu, effects.resources.cpuMillis / 1000),
          line(l10n.serverPluginsDisk, effects.resources.minimumDiskMiB),
          line(l10n.serverPluginsProcesses, effects.resources.pidsLimit),
          heading(l10n.serverPluginsSecurity),
          Text(effects.security.user),
          Text(l10n.serverPluginsSecurityHint),
          for (final warning in effects.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_warning(l10n, warning)),
            ),
        ],
      ),
      actions: [
        CupertinoButton(
          key: const ValueKey('plugin-preview-close'),
          onPressed: () {
            if (widget.current()) Navigator.pop(context);
          },
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

String _warning(AppLocalizations l10n, String warning) => switch (warning) {
  'lan_port_exposure' => l10n.serverPluginsWarningLan,
  'initial_setup_required' => l10n.serverPluginsWarningSetup,
  'resource_budget_unverified' => l10n.serverPluginsWarningResources,
  'writable_shared_library' => l10n.serverPluginsWarningWritable,
  'library_paths_require_setup' => l10n.serverPluginsWarningLibrary,
  'non_root_ownership_required' => l10n.serverPluginsWarningOwnership,
  'hardware_acceleration_not_configured' => l10n.serverPluginsWarningHardware,
  'discovery_not_published' => l10n.serverPluginsWarningDiscovery,
  'host_network' => l10n.serverPluginsNetworkHost,
  'airplay_ptp_319_320' => l10n.serverPluginsWarningAirplay,
  'dynamic_receiver_ports' => l10n.serverPluginsWarningDynamic,
  _ => l10n.serverPluginsImageUnverified,
};
