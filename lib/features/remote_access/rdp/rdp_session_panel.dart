import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_bridge.dart';
import '../../../core/window/window_policy_models.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/remote_profiles.dart';
import 'rdp_display_geometry.dart';
import 'rdp_engine.dart';
import 'rdp_models.dart';
import 'rdp_security_store.dart';
import 'rdp_session_controller.dart';

final rdpEngineFactoryProvider = Provider<RdpEngine Function()>(
  (_) => RdpMethodChannelEngine.new,
);
final rdpSecurityStoreProvider = Provider<RdpSecurityStore>(
  (_) => RdpSecurityStore(),
);
final rdpTrustStoreProvider = Provider<RdpTrustStore>(
  (ref) => ref.watch(rdpSecurityStoreProvider),
);

class RdpSessionPanel extends ConsumerStatefulWidget {
  const RdpSessionPanel({
    super.key,
    required this.profile,
    required this.isCurrent,
    required this.onBack,
    this.securityStore,
  });
  final RemoteProfile profile;
  final bool Function() isCurrent;
  final VoidCallback onBack;
  final RdpSecurityStore? securityStore;
  @override
  ConsumerState<RdpSessionPanel> createState() => _RdpSessionPanelState();
}

class _RdpSessionPanelState extends ConsumerState<RdpSessionPanel>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  final _gatewayPassword = TextEditingController();
  final _domain = TextEditingController();
  final _gatewayHost = TextEditingController();
  final _gatewayPort = TextEditingController(text: '443');
  final _gatewayUser = TextEditingController();
  final _remoteText = TextEditingController();
  final _surfaceKey = GlobalKey<_RdpInputSurfaceState>();
  ProviderContainer? _container;
  AppInteractionController? _interaction;
  RdpSessionController? _controller;
  RdpEngine Function()? _factory;
  RdpTrustStore? _trust;
  RdpSecurityStore? _security;
  RdpProfileSettings _settings = const RdpProfileSettings();
  bool _settingsStarted = false, _settingsLoaded = false, _settingsBusy = false;
  bool _rememberCredential = false;
  String? _settingsNotice;
  bool _resumed = true, _focused = true, _retired = false;
  WindowDisplayIdentity? _controllerDisplayIdentity;
  bool _clipboardBusy = false;
  bool _remoteAudioRequested = false;
  RdpClipboardSendResult? _clipboardNotice;
  RdpSessionPhase? _observedSessionPhase;
  int _sessionRevision = 0;
  int _fullscreenGeneration = 0;
  bool _fullscreenBusy = false;
  bool _fullscreenDenied = false;
  OverlayEntry? _fullscreenEntry;
  WindowFullscreenLease? _fullscreenLease;
  WindowPolicyBridge? _fullscreenBridge;
  bool _consumeFullscreenEscapeRelease = false;
  Timer? _fullscreenEscapeTimer;

  WindowDisplayIdentity? _loadedDisplayIdentity() {
    final state = ref.read(windowPolicySnapshotProvider);
    if (!state.hasValue || state.isLoading || state.hasError) return null;
    return state.requireValue.displayIdentity;
  }

  bool _current() {
    try {
      if (_retired ||
          !mounted ||
          !_resumed ||
          !_focused ||
          !widget.isCurrent() ||
          !identical(
            _container,
            ProviderScope.containerOf(context, listen: false),
          ) ||
          _interaction?.active != true ||
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.of(context)?.isCurrent != true ||
          !identical(_factory, ref.read(rdpEngineFactoryProvider)) ||
          !identical(
            _trust,
            widget.securityStore ?? ref.read(rdpTrustStoreProvider),
          ) ||
          !identical(
            _security,
            widget.securityStore ?? ref.read(rdpSecurityStoreProvider),
          )) {
        return false;
      }
      final state = ref.read(windowPolicySnapshotProvider);
      if (!state.hasValue || state.isLoading || state.hasError) return false;
      final value = state.requireValue;
      return !value.supported ||
          value.isResumed && value.hasWindowFocus && !value.isPictureInPicture;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = ProviderScope.containerOf(context, listen: false),
        interaction = AppInteractionScope.maybeOf(context);
    if (_container != null && !identical(container, _container)) _retire();
    _container = container;
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_ownerChanged);
      _interaction = interaction;
      interaction?.addListener(_ownerChanged);
    }
    _factory ??= ref.read(rdpEngineFactoryProvider);
    _trust ??= widget.securityStore ?? ref.read(rdpTrustStoreProvider);
    _security ??= widget.securityStore ?? ref.read(rdpSecurityStoreProvider);
    if (_controller == null) {
      _controller = _newController(displayIdentity: _loadedDisplayIdentity())
        ..addListener(_changed);
      _observedSessionPhase = _controller!.phase;
      _sessionRevision++;
    }
    if (!_settingsStarted) {
      _settingsStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
    }
    _fullscreenEntry?.markNeedsBuild();
    if (!TickerMode.valuesOf(context).enabled) _retire();
  }

  @override
  void didUpdateWidget(covariant RdpSessionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.securityStore, widget.securityStore) ||
        !identical(oldWidget.profile, widget.profile)) {
      _retire();
    }
  }

  RdpSessionController _newController({
    required WindowDisplayIdentity? displayIdentity,
  }) {
    _controllerDisplayIdentity = displayIdentity;
    final media = MediaQuery.of(context), size = media.size;
    return RdpSessionController(
      profile: widget.profile,
      trust: _trust!,
      credentialVault: _security,
      engineFactory: _factory!,
      isCurrent: () =>
          _current() &&
          displayIdentity != null &&
          _loadedDisplayIdentity() == displayIdentity,
      display: RdpDisplaySpec.fromViewport(
        widthPixels: (size.width * media.devicePixelRatio).round(),
        heightPixels: (size.height * media.devicePixelRatio).round(),
        devicePixelRatio: media.devicePixelRatio,
        externalDisplay: displayIdentity?.isExternalDisplay ?? false,
      ),
      settings: _settings,
      remoteAudio: _remoteAudioRequested,
    );
  }

  void _replaceController({
    required WindowDisplayIdentity? displayIdentity,
    bool force = false,
  }) {
    if (!force && _controllerDisplayIdentity == displayIdentity) return;
    _retireFullscreen(notify: false);
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _controller = _newController(displayIdentity: displayIdentity)
      ..addListener(_changed);
    _observedSessionPhase = _controller!.phase;
    _sessionRevision++;
  }

  void _fillSettings(RdpProfileSettings value) {
    _domain.text = value.domain;
    _gatewayHost.text = value.gatewayHost ?? '';
    _gatewayPort.text = '${value.gatewayPort}';
    _gatewayUser.text = value.gatewayUsername;
  }

  Future<void> _loadSettings() async {
    if (!_current()) return;
    try {
      final value = await _security!.readSettings(
        widget.profile,
        isCurrent: _current,
      );
      if (!_current()) return;
      _settings = value;
      _fillSettings(value);
      _settingsLoaded = true;
      _replaceController(
        displayIdentity: _loadedDisplayIdentity(),
        force: true,
      );
      if (mounted) setState(() {});
    } catch (_) {
      if (_current() && mounted) {
        setState(() {
          _settingsLoaded = true;
          _settingsNotice = 'failed';
        });
      }
    }
  }

  Future<void> _connect() async {
    final before = _loadedDisplayIdentity();
    if (before == null) return;
    if (_controllerDisplayIdentity != before) {
      _replaceController(displayIdentity: before);
    }
    if (!_settingsLoaded) await _loadSettings();
    final after = _loadedDisplayIdentity();
    if (after == null || after != before) {
      _replaceController(displayIdentity: after);
      return;
    }
    if (_current() && _settingsLoaded && _controllerDisplayIdentity == after) {
      await _controller!.connect();
    }
  }

  Future<void> _saveSettings() async {
    if (!_current() || !_settingsLoaded || _settingsBusy) return;
    final capabilities = _controller?.capabilities;
    if (_settings.clipboardMode != RdpClipboardMode.disabled &&
        capabilities != null &&
        !capabilities.supportedClipboardModes.contains(
          _settings.clipboardMode,
        )) {
      setState(() => _settingsNotice = 'failed');
      return;
    }
    setState(() {
      _settingsBusy = true;
      _settingsNotice = null;
    });
    try {
      final gateway = _gatewayHost.text.trim();
      final value = RdpProfileSettings(
        domain: _domain.text.trim(),
        gatewayHost: gateway.isEmpty ? null : normalizeRemoteHost(gateway),
        gatewayPort: int.tryParse(_gatewayPort.text) ?? -1,
        gatewayUsername: _gatewayUser.text.trim(),
        displayMode: _settings.displayMode,
        keyboardLayout: _settings.keyboardLayout,
        clipboardMode: _settings.clipboardMode,
      );
      value.validate();
      await _security!.saveSettings(widget.profile, value, isCurrent: _current);
      if (!_current()) return;
      _settings = value;
      _replaceController(
        displayIdentity: _loadedDisplayIdentity(),
        force: true,
      );
      setState(() => _settingsNotice = 'saved');
    } catch (_) {
      if (_current()) setState(() => _settingsNotice = 'failed');
    } finally {
      if (_current()) setState(() => _settingsBusy = false);
    }
  }

  void _changed() {
    if (!mounted) return;
    final phase = _controller?.phase;
    if (phase != _observedSessionPhase) {
      _observedSessionPhase = phase;
      _sessionRevision++;
    }
    if (phase != RdpSessionPhase.connected) {
      _retireFullscreen(notify: false);
    }
    if (_controller?.hasSensitiveInput != true) {
      _password.clear();
      _gatewayPassword.clear();
      _rememberCredential = false;
    }
    if (_controller?.phase != RdpSessionPhase.connected) {
      _remoteText.clear();
      _clipboardNotice = null;
    }
    setState(() {});
  }

  bool _fullscreenWindowCurrent(
    WindowPolicySnapshot value,
    WindowDisplayIdentity display,
  ) =>
      value.supported &&
      value.displayIdentity == display &&
      value.isResumed &&
      value.hasWindowFocus &&
      !value.isMultiWindow &&
      !value.isPictureInPicture &&
      !value.isExternalDisplay &&
      value.captionVisible == false &&
      value.imeVisible != null &&
      (value.reason == WindowRestrictionReason.none ||
          value.reason == WindowRestrictionReason.keyboard);

  bool _fullscreenRequestCurrent({
    required int generation,
    required int sessionRevision,
    required RdpSessionController controller,
    required RemoteProfile profile,
    required ProviderContainer container,
    required ModalRoute<Object?> route,
    required WindowDisplayIdentity display,
    required WindowPolicyBridge bridge,
  }) {
    if (generation != _fullscreenGeneration ||
        !_current() ||
        sessionRevision != _sessionRevision ||
        !identical(controller, _controller) ||
        controller.phase != RdpSessionPhase.connected ||
        !identical(profile, widget.profile) ||
        !identical(container, _container) ||
        !identical(route, ModalRoute.of(context)) ||
        !route.isCurrent ||
        !identical(bridge, ref.read(windowPolicyBridgeProvider)) ||
        _controllerDisplayIdentity != display ||
        _loadedDisplayIdentity() != display) {
      return false;
    }
    final state = ref.read(windowPolicySnapshotProvider);
    return state.hasValue &&
        !state.isLoading &&
        !state.hasError &&
        _fullscreenWindowCurrent(state.requireValue, display);
  }

  Future<void> _releaseFullscreen(
    WindowPolicyBridge bridge,
    WindowFullscreenLease lease,
  ) async {
    try {
      await bridge.releaseFullscreen(lease);
    } catch (_) {
      // The exact native owner still retires on lifecycle/display loss.
    }
  }

  void _clearFullscreenEscapeRelease() {
    _fullscreenEscapeTimer?.cancel();
    _fullscreenEscapeTimer = null;
    if (!_consumeFullscreenEscapeRelease) return;
    _consumeFullscreenEscapeRelease = false;
    if (mounted) setState(() {});
  }

  KeyEventResult _fullscreenEscape(KeyEvent event) {
    if (event is KeyDownEvent && !_consumeFullscreenEscapeRelease) {
      _consumeFullscreenEscapeRelease = true;
      _fullscreenEscapeTimer?.cancel();
      _fullscreenEscapeTimer = Timer(
        const Duration(seconds: 1),
        _clearFullscreenEscapeRelease,
      );
      _retireFullscreen();
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _pendingFullscreenEscape(KeyEvent event) {
    if (event is KeyUpEvent) _clearFullscreenEscapeRelease();
    return KeyEventResult.handled;
  }

  void _retireFullscreen({bool notify = true}) {
    _fullscreenGeneration++;
    final entry = _fullscreenEntry,
        lease = _fullscreenLease,
        bridge = _fullscreenBridge;
    _fullscreenEntry = null;
    _fullscreenLease = null;
    _fullscreenBridge = null;
    _fullscreenBusy = false;
    _fullscreenDenied = false;
    entry?.remove();
    if (lease != null && bridge != null) {
      unawaited(_releaseFullscreen(bridge, lease));
    }
    if (notify && mounted) setState(() {});
  }

  Future<void> _enterFullscreen() async {
    final controller = _controller,
        display = _loadedDisplayIdentity(),
        route = ModalRoute.of(context),
        container = _container;
    if (_fullscreenBusy ||
        _fullscreenEntry != null ||
        !_current() ||
        controller == null ||
        controller.phase != RdpSessionPhase.connected ||
        display == null ||
        route == null ||
        container == null) {
      return;
    }
    final bridge = ref.read(windowPolicyBridgeProvider);
    final generation = ++_fullscreenGeneration;
    final sessionRevision = _sessionRevision;
    final profile = widget.profile;
    setState(() {
      _fullscreenBusy = true;
      _fullscreenDenied = false;
    });
    WindowFullscreenLease? lease;
    try {
      lease = await bridge.acquireFullscreen(display);
    } catch (_) {
      if (_fullscreenRequestCurrent(
        generation: generation,
        sessionRevision: sessionRevision,
        controller: controller,
        profile: profile,
        container: container,
        route: route,
        display: display,
        bridge: bridge,
      )) {
        setState(() {
          _fullscreenBusy = false;
          _fullscreenDenied = true;
        });
      }
      return;
    }
    if (!mounted) {
      if (lease != null) await _releaseFullscreen(bridge, lease);
      return;
    }
    if (!_fullscreenRequestCurrent(
      generation: generation,
      sessionRevision: sessionRevision,
      controller: controller,
      profile: profile,
      container: container,
      route: route,
      display: display,
      bridge: bridge,
    )) {
      if (lease != null) await _releaseFullscreen(bridge, lease);
      return;
    }
    if (lease == null) {
      setState(() {
        _fullscreenBusy = false;
        _fullscreenDenied = true;
      });
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      await _releaseFullscreen(bridge, lease);
      if (_fullscreenRequestCurrent(
        generation: generation,
        sessionRevision: sessionRevision,
        controller: controller,
        profile: profile,
        container: container,
        route: route,
        display: display,
        bridge: bridge,
      )) {
        setState(() {
          _fullscreenBusy = false;
          _fullscreenDenied = true;
        });
      }
      return;
    }
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) =>
          _fullscreenSurface(context, controller: controller, entry: entry),
    );
    _fullscreenLease = lease;
    _fullscreenBridge = bridge;
    _fullscreenEntry = entry;
    _fullscreenBusy = false;
    try {
      overlay.insert(entry);
    } catch (_) {
      _fullscreenEntry = null;
      _fullscreenLease = null;
      _fullscreenBridge = null;
      await _releaseFullscreen(bridge, lease);
      if (_fullscreenRequestCurrent(
        generation: generation,
        sessionRevision: sessionRevision,
        controller: controller,
        profile: profile,
        container: container,
        route: route,
        display: display,
        bridge: bridge,
      )) {
        setState(() => _fullscreenDenied = true);
      }
      return;
    }
    if (mounted) setState(() {});
  }

  Widget _fullscreenSurface(
    BuildContext context, {
    required RdpSessionController controller,
    required OverlayEntry entry,
  }) {
    if (!identical(entry, _fullscreenEntry) ||
        !identical(controller, _controller) ||
        controller.phase != RdpSessionPhase.connected) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    return Semantics(
      key: const ValueKey('rdp-fullscreen-overlay'),
      container: true,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: l.rdpFullscreenSurface,
      child: ColoredBox(
        color: CupertinoColors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: _RdpInputSurface(
                key: _surfaceKey,
                controller: controller,
                label: l.rdpInputReady,
                mode: _settings.displayMode,
                panEnableLabel: l.rdpNativePanEnable,
                panDisableLabel: l.rdpNativePanDisable,
                expand: true,
                onEscape: _fullscreenEscape,
              ),
            ),
            PositionedDirectional(
              top: 0,
              end: 0,
              child: SafeArea(
                minimum: const EdgeInsets.all(12),
                child: Semantics(
                  button: true,
                  label: l.rdpFullscreenExit,
                  child: CupertinoButton(
                    key: const ValueKey('rdp-fullscreen-exit'),
                    minimumSize: const Size(48, 48),
                    padding: EdgeInsets.zero,
                    color: CupertinoColors.systemGrey
                        .resolveFrom(context)
                        .withValues(alpha: .8),
                    onPressed: _retireFullscreen,
                    child: const Icon(
                      CupertinoIcons.arrow_down_right_arrow_up_left,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _sendText() {
    final value = _remoteText.text;
    if (!_current() || _controller?.phase != RdpSessionPhase.connected) {
      _remoteText.clear();
      return;
    }
    _controller!.text(value);
    _remoteText.clear();
  }

  Future<void> _sendClipboard() async {
    final controller = _controller;
    if (!_current() ||
        controller == null ||
        !controller.canSendClipboard ||
        _clipboardBusy) {
      return;
    }
    setState(() {
      _clipboardBusy = true;
      _clipboardNotice = null;
    });
    try {
      final outcome = await controller.sendClipboardFrom(
        () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      );
      if (_current() &&
          identical(controller, _controller) &&
          controller.canSendClipboard) {
        setState(() => _clipboardNotice = outcome);
      }
    } finally {
      if (mounted) setState(() => _clipboardBusy = false);
    }
  }

  void _ownerChanged() {
    if (!_current()) _retire();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _retireFullscreen(notify: false);
    _password.clear();
    _gatewayPassword.clear();
    _remoteText.clear();
    _clipboardNotice = null;
    for (final field in [_domain, _gatewayHost, _gatewayPort, _gatewayUser]) {
      field.clear();
    }
    _controller?.retire();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _retire();
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (event.viewId != View.of(context).viewId) return;
    _focused = event.state == ui.ViewFocusState.focused;
    if (!_focused) _retire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fullscreenEscapeTimer?.cancel();
    _retireFullscreen(notify: false);
    _interaction?.removeListener(_ownerChanged);
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _password.dispose();
    _gatewayPassword.dispose();
    _domain.dispose();
    _gatewayHost.dispose();
    _gatewayPort.dispose();
    _gatewayUser.dispose();
    _remoteText.dispose();
    super.dispose();
  }

  String _status(AppLocalizations l, RdpSessionController c) =>
      switch (c.phase) {
        RdpSessionPhase.idle => l.rdpProfileHint,
        RdpSessionPhase.checking => l.rdpChecking,
        RdpSessionPhase.unsupported => l.rdpEngineUnavailable,
        RdpSessionPhase.certificate => l.rdpCertificateReview,
        RdpSessionPhase.nlaRequired => l.rdpNlaPassword,
        RdpSessionPhase.connecting => l.rdpConnecting,
        RdpSessionPhase.connected => l.rdpConnected,
        RdpSessionPhase.closed => l.rdpClosed,
        RdpSessionPhase.failed => switch (c.error) {
          'tls_required' => l.rdpTlsRequired,
          'nla_unsupported' => l.rdpNlaUnsupported,
          'certificate_changed' => l.rdpCertificateChanged,
          _ => l.rdpFailed,
        },
      };

  @override
  Widget build(BuildContext context) {
    ref.listen(windowPolicySnapshotProvider, (_, next) {
      final value = next.value;
      final fullscreenDisplay =
          _fullscreenLease?.display ??
          (_fullscreenBusy ? _controllerDisplayIdentity : null);
      if ((_fullscreenEntry != null || _fullscreenBusy) &&
          (next.isLoading ||
              next.hasError ||
              value == null ||
              fullscreenDisplay == null ||
              !_fullscreenWindowCurrent(value, fullscreenDisplay))) {
        _retireFullscreen();
      }
      if (next.isLoading ||
          next.hasError ||
          value == null ||
          value.supported &&
              (!value.isResumed ||
                  !value.hasWindowFocus ||
                  value.isPictureInPicture)) {
        _retire();
      } else if (_controllerDisplayIdentity != value.displayIdentity) {
        _replaceController(displayIdentity: value.displayIdentity);
        if (mounted) setState(() {});
      } else if (!_settingsLoaded && !_settingsBusy) {
        unawaited(_loadSettings());
      }
    });
    ref.watch(windowPolicySnapshotProvider);
    final l = AppLocalizations.of(context), c = _controller!;
    final displayIdentity = _loadedDisplayIdentity();
    Widget action(String key, String title, VoidCallback? callback) =>
        SettingsActionTile(
          key: ValueKey(key),
          title: Text(title),
          onTap: !_current() || callback == null ? null : callback,
        );
    Widget field(
      String key,
      String label,
      TextEditingController controller, {
      TextInputType? type,
    }) => Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 6),
          CupertinoTextField(
            key: ValueKey(key),
            controller: controller,
            enabled: _current() && !_settingsBusy,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: type,
            padding: const EdgeInsets.all(14),
          ),
        ],
      ),
    );
    return AppPageScaffold(
      key: const ValueKey('rdp-session-panel'),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: CustomScrollView(
              key: const ValueKey('rdp-scroll'),
              slivers: [
                CupertinoSliverNavigationBar(
                  leading: CupertinoButton(
                    key: const ValueKey('rdp-back'),
                    minimumSize: const Size(48, 48),
                    padding: EdgeInsets.zero,
                    onPressed: _current() ? widget.onBack : null,
                    child: const Icon(CupertinoIcons.back),
                  ),
                  largeTitle: Text(l.rdpTitle),
                ),
                SliverList(
                  delegate: SliverChildListDelegate([
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          displayIdentity == null
                              ? l.windowUnsupported
                              : _status(l, c),
                          key: const ValueKey('rdp-status'),
                        ),
                      ),
                    ),
                    SettingsSection(
                      children: [
                        field('rdp-settings-domain', l.rdpDomain, _domain),
                        field(
                          'rdp-settings-gateway-host',
                          l.rdpGatewayHost,
                          _gatewayHost,
                          type: TextInputType.url,
                        ),
                        field(
                          'rdp-settings-gateway-port',
                          l.rdpGatewayPort,
                          _gatewayPort,
                          type: TextInputType.number,
                        ),
                        field(
                          'rdp-settings-gateway-user',
                          l.rdpGatewayUsername,
                          _gatewayUser,
                        ),
                        for (final value in RdpDisplayMode.values)
                          action(
                            'rdp-display-${value.name}',
                            '${switch (value) {
                              RdpDisplayMode.fitWindow => l.rdpDisplayFitWindow,
                              RdpDisplayMode.fillWindow => l.rdpDisplayFillWindow,
                              RdpDisplayMode.native => l.rdpDisplayNative,
                            }}${_settings.displayMode == value ? ' ✓' : ''}',
                            () => setState(
                              () => _settings = _settings.copyWith(
                                displayMode: value,
                              ),
                            ),
                          ),
                        for (final value in RdpKeyboardLayout.values)
                          action(
                            'rdp-keyboard-${value.name}',
                            '${switch (value) {
                              RdpKeyboardLayout.automatic => l.rdpKeyboardAutomatic,
                              RdpKeyboardLayout.turkishQ => l.rdpKeyboardTurkishQ,
                              RdpKeyboardLayout.us => l.rdpKeyboardUs,
                            }}${_settings.keyboardLayout == value ? ' ✓' : ''}',
                            () => setState(
                              () => _settings = _settings.copyWith(
                                keyboardLayout: value,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: Text(l.rdpRemoteSound)),
                                  Semantics(
                                    label: l.rdpRemoteSound,
                                    child: CupertinoSwitch(
                                      key: const ValueKey('rdp-audio-enable'),
                                      value: _remoteAudioRequested,
                                      onChanged:
                                          _current() &&
                                              (c.phase ==
                                                      RdpSessionPhase.idle ||
                                                  c.phase ==
                                                      RdpSessionPhase.closed ||
                                                  c.phase ==
                                                      RdpSessionPhase.failed) &&
                                              (_remoteAudioRequested ||
                                                  c
                                                          .capabilities
                                                          ?.supportsAudio !=
                                                      false)
                                          ? (value) => setState(() {
                                              _remoteAudioRequested = value;
                                              _replaceController(
                                                displayIdentity:
                                                    displayIdentity,
                                                force: true,
                                              );
                                            })
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(l.rdpRemoteSoundHint),
                            ],
                          ),
                        ),
                        for (final value in RdpClipboardMode.values.where(
                          (value) =>
                              value == RdpClipboardMode.disabled ||
                              c.capabilities?.supportedClipboardModes.contains(
                                    value,
                                  ) ==
                                  true ||
                              value == _settings.clipboardMode,
                        ))
                          action(
                            'rdp-clipboard-${value.name}',
                            '${switch (value) {
                              RdpClipboardMode.disabled => l.rdpClipboardDisabled,
                              RdpClipboardMode.clientToRemote => l.rdpClipboardClientToRemote,
                              RdpClipboardMode.bidirectional => l.rdpClipboardBidirectional,
                            }}${_settings.clipboardMode == value ? ' ✓' : ''}',
                            value != RdpClipboardMode.disabled &&
                                    c.capabilities?.supportedClipboardModes
                                            .contains(value) !=
                                        true
                                ? null
                                : () => setState(
                                    () => _settings = _settings.copyWith(
                                      clipboardMode: value,
                                    ),
                                  ),
                          ),
                        if (_settings.clipboardMode !=
                                RdpClipboardMode.disabled &&
                            c.capabilities != null &&
                            c.capabilities?.supportedClipboardModes.contains(
                                  _settings.clipboardMode,
                                ) !=
                                true)
                          Padding(
                            key: const ValueKey(
                              'rdp-clipboard-correction-required',
                            ),
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              Localizations.localeOf(context).languageCode ==
                                      'tr'
                                  ? 'Kayıtlı pano modu bu aygıtta kullanılamıyor. Kapalı veya desteklenen tek yönlü modu seçip kaydedin.'
                                  : 'The saved clipboard mode is unavailable on this device. Choose Off or a supported one-way mode and save.',
                            ),
                          ),
                        action(
                          'rdp-settings-save',
                          l.commonSave,
                          _settingsLoaded
                              ? () => unawaited(_saveSettings())
                              : null,
                        ),
                        if (_settingsNotice != null)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _settingsNotice == 'saved'
                                    ? l.rdpSettingsSaved
                                    : l.rdpSettingsInvalid,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.rdpDisplay,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                l.rdpDisplayValue(
                                  c.requestedDisplay.width,
                                  c.requestedDisplay.height,
                                  c.requestedDisplay.desktopScaleFactor,
                                  c.requestedDisplay.deviceScaleFactor,
                                ),
                              ),
                              if (c.requestedDisplay.externalDisplay)
                                Text(l.rdpExternalDisplay),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(switch (_settings.clipboardMode) {
                                RdpClipboardMode.disabled => l.rdpClipboardOff,
                                RdpClipboardMode.clientToRemote =>
                                  l.rdpClipboardClientToRemote,
                                RdpClipboardMode.bidirectional =>
                                  l.rdpClipboardBidirectional,
                              }),
                              Text(
                                !_remoteAudioRequested
                                    ? l.rdpAudioOff
                                    : switch (c.audioObservation?.state) {
                                        RdpAudioState.closed =>
                                          l.rdpAudioClosed,
                                        RdpAudioState.failed =>
                                          l.rdpAudioUnavailable,
                                        _ =>
                                          c.phase == RdpSessionPhase.failed ||
                                                  c.phase ==
                                                      RdpSessionPhase
                                                          .unsupported
                                              ? l.rdpAudioUnavailable
                                              : c
                                                        .audioObservation
                                                        ?.hasCompletedPlayback ==
                                                    true
                                              ? l.rdpAudioPlaying
                                              : c.phase ==
                                                    RdpSessionPhase.connected
                                              ? l.rdpAudioWaiting
                                              : l.rdpAudioEnabled,
                                      },
                                key: const ValueKey('rdp-audio-status'),
                              ),
                              Text(l.rdpFilesOff),
                              const SizedBox(height: 8),
                              Text(l.rdpChannelsHint),
                            ],
                          ),
                        ),
                        if (c.phase == RdpSessionPhase.idle)
                          action(
                            'rdp-check',
                            l.rdpCheck,
                            displayIdentity == null
                                ? null
                                : () => unawaited(_connect()),
                          ),
                        if (c.phase == RdpSessionPhase.certificate) ...[
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: SelectableText(
                              c.pendingCertificate!.fingerprint,
                            ),
                          ),
                          action(
                            'rdp-trust',
                            l.rdpTrustCertificate,
                            () => unawaited(c.trustCertificate()),
                          ),
                        ],
                        if (c.phase == RdpSessionPhase.nlaRequired) ...[
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: CupertinoTextField(
                              key: const ValueKey('rdp-password'),
                              controller: _password,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              maxLength: 4096,
                              placeholder: l.rdpNlaPassword,
                              padding: const EdgeInsets.all(14),
                              onSubmitted: (_) => unawaited(
                                c.authenticate(
                                  _password.text,
                                  gatewayPassword: _gatewayPassword.text,
                                  remember: _rememberCredential,
                                ),
                              ),
                            ),
                          ),
                          if (_settings.gatewayHost != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: CupertinoTextField(
                                key: const ValueKey('rdp-gateway-password'),
                                controller: _gatewayPassword,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                maxLength: 4096,
                                placeholder: l.rdpGatewayPassword,
                                padding: const EdgeInsets.all(14),
                              ),
                            ),
                          action(
                            'rdp-remember-credential',
                            '${l.rdpRememberCredential}${_rememberCredential ? ' ✓' : ''}',
                            () => setState(
                              () => _rememberCredential = !_rememberCredential,
                            ),
                          ),
                          action(
                            'rdp-authenticate',
                            l.rdpAuthenticate,
                            () => unawaited(
                              c.authenticate(
                                _password.text,
                                gatewayPassword: _gatewayPassword.text,
                                remember: _rememberCredential,
                              ),
                            ),
                          ),
                        ],
                        if (c.phase == RdpSessionPhase.connected &&
                            displayIdentity != null) ...[
                          if (_fullscreenEntry == null)
                            _RdpInputSurface(
                              key: _surfaceKey,
                              controller: c,
                              label: l.rdpInputReady,
                              mode: _settings.displayMode,
                              panEnableLabel: l.rdpNativePanEnable,
                              panDisableLabel: l.rdpNativePanDisable,
                              onEscape: _consumeFullscreenEscapeRelease
                                  ? _pendingFullscreenEscape
                                  : null,
                            ),
                          action(
                            'rdp-fullscreen-enter',
                            l.rdpFullscreenEnter,
                            _fullscreenBusy || _fullscreenEntry != null
                                ? null
                                : () => unawaited(_enterFullscreen()),
                          ),
                          if (_fullscreenBusy)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Center(
                                child: CupertinoActivityIndicator(
                                  key: ValueKey('rdp-fullscreen-progress'),
                                ),
                              ),
                            ),
                          if (_fullscreenDenied)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  l.rdpFullscreenDenied,
                                  key: const ValueKey('rdp-fullscreen-denied'),
                                ),
                              ),
                            ),
                          if (c.canSendClipboard) ...[
                            action(
                              'rdp-clipboard-send',
                              l.rdpClipboardSend,
                              _clipboardBusy
                                  ? null
                                  : () => unawaited(_sendClipboard()),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Semantics(
                                liveRegion: true,
                                child: _clipboardBusy
                                    ? const CupertinoActivityIndicator()
                                    : Text(switch (_clipboardNotice) {
                                        RdpClipboardSendResult.submitted =>
                                          l.rdpClipboardSubmitted,
                                        RdpClipboardSendResult.empty =>
                                          l.rdpClipboardEmpty,
                                        RdpClipboardSendResult.invalid =>
                                          l.rdpClipboardInvalid,
                                        RdpClipboardSendResult.failed =>
                                          l.rdpClipboardFailed,
                                        _ => l.rdpClipboardHint,
                                      }),
                              ),
                            ),
                          ],
                          if (c.supportsUnicodeInput) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                              child: CupertinoTextField(
                                key: const ValueKey('rdp-text-input'),
                                controller: _remoteText,
                                maxLength: 1024,
                                autocorrect: false,
                                enableSuggestions: false,
                                textInputAction: TextInputAction.send,
                                placeholder: l.rdpTextInput,
                                padding: const EdgeInsets.all(14),
                                onSubmitted: (_) => _sendText(),
                              ),
                            ),
                            action('rdp-text-send', l.rdpTextSend, _sendText),
                          ],
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Semantics(
                              container: true,
                              label: l.rdpInputReady,
                              child: Text(l.rdpInputReady),
                            ),
                          ),
                          action(
                            'rdp-disconnect',
                            l.rdpDisconnect,
                            c.disconnect,
                          ),
                        ],
                        if (c.phase == RdpSessionPhase.closed ||
                            c.phase == RdpSessionPhase.failed)
                          action(
                            'rdp-reconnect',
                            l.rdpReconnect,
                            displayIdentity == null
                                ? null
                                : () => unawaited(c.reconnect()),
                          ),
                      ],
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RdpInputSurface extends StatefulWidget {
  const _RdpInputSurface({
    super.key,
    required this.controller,
    required this.label,
    required this.mode,
    required this.panEnableLabel,
    required this.panDisableLabel,
    this.expand = false,
    this.onEscape,
  });
  final RdpSessionController controller;
  final String label;
  final RdpDisplayMode mode;
  final String panEnableLabel;
  final String panDisableLabel;
  final bool expand;
  final KeyEventResult Function(KeyEvent event)? onEscape;

  @override
  State<_RdpInputSurface> createState() => _RdpInputSurfaceState();
}

class _RdpInputSurfaceState extends State<_RdpInputSurface> {
  final _focus = FocusNode(debugLabel: 'RDP desktop input');
  RdpDisplaySpec? _lastRequestedDisplay;
  StreamSubscription<RdpFrame>? _frames;
  ui.Image? _image;
  RdpFrame? _displayedFrame;
  int _frameGeneration = 0;
  Offset _nativePan = Offset.zero;
  double _wheelRemainder = 0;
  bool _nativePanEnabled = false;
  int? _activeRemotePointer;
  Offset? _lastRemotePointer;
  final _rejectedRemotePointers = <int>{};

  @override
  void initState() {
    super.initState();
    _frames = widget.controller.frames.listen(_frame);
  }

  @override
  void didUpdateWidget(covariant _RdpInputSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_frames?.cancel());
      _frames = widget.controller.frames.listen(_frame);
      _image?.dispose();
      _image = null;
      _displayedFrame = null;
      _frameGeneration++;
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.mode != widget.mode) {
      _lastRequestedDisplay = null;
      _nativePan = Offset.zero;
      _wheelRemainder = 0;
      _nativePanEnabled = false;
      _activeRemotePointer = null;
      _lastRemotePointer = null;
      _rejectedRemotePointers.clear();
    }
  }

  void _frame(RdpFrame frame) {
    final generation = ++_frameGeneration;
    ui.decodeImageFromPixels(
      frame.bgra,
      frame.width,
      frame.height,
      ui.PixelFormat.bgra8888,
      (image) {
        frame.bgra.fillRange(0, frame.bgra.length, 0);
        if (!mounted || generation != _frameGeneration) {
          image.dispose();
          return;
        }
        unawaited(_acknowledgeAndInstall(frame, image, generation));
      },
      rowBytes: frame.stride,
    );
  }

  Future<void> _acknowledgeAndInstall(
    RdpFrame frame,
    ui.Image image,
    int generation,
  ) async {
    final controller = widget.controller;
    final accepted = await controller.acknowledgeFrame(frame);
    if (!accepted ||
        !mounted ||
        generation != _frameGeneration ||
        !identical(controller, widget.controller)) {
      image.dispose();
      return;
    }
    final old = _image;
    setState(() {
      _image = image;
      _displayedFrame = frame;
    });
    old?.dispose();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (widget.onEscape != null &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      return widget.onEscape!(event);
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent && event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final physical = event.physicalKey.usbHidUsage;
    final remote = RdpKeyEvent(
      physicalKey: physical,
      down: event is KeyDownEvent,
    );
    if (!remote.supported) return KeyEventResult.ignored;
    widget.controller.key(remote);
    return KeyEventResult.handled;
  }

  void _resize(Size size) {
    if (widget.mode == RdpDisplayMode.native || size.isEmpty) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final current = widget.controller.requestedDisplay;
    final requested = RdpDisplaySpec.fromViewport(
      widthPixels: (size.width * ratio).round(),
      heightPixels: (size.height * ratio).round(),
      devicePixelRatio: ratio,
      externalDisplay: current.externalDisplay,
    );
    if (requested == _lastRequestedDisplay) return;
    _lastRequestedDisplay = requested;
    final controller = widget.controller;
    final mode = widget.mode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          mode == RdpDisplayMode.native ||
          widget.mode != mode ||
          !identical(widget.controller, controller)) {
        return;
      }
      controller.resize(requested);
    });
  }

  RdpDisplayGeometry? _geometry(Size size) {
    final image = _image;
    if (image == null || size.isEmpty) return null;
    return RdpDisplayGeometry.calculate(
      mode: widget.mode,
      frameSize: Size(image.width.toDouble(), image.height.toDouble()),
      viewportSize: size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      nativePan: _nativePan,
    );
  }

  void _pointer(PointerEvent event, Size size) {
    final normalized = _geometry(size)?.normalize(event.localPosition);
    if (event is PointerDownEvent) {
      if ((widget.mode == RdpDisplayMode.native && _nativePanEnabled) ||
          normalized == null ||
          _activeRemotePointer != null) {
        _rejectedRemotePointers.add(event.pointer);
        return;
      }
      _activeRemotePointer = event.pointer;
      _lastRemotePointer = normalized;
      _sendPointer(normalized, event.buttons);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_rejectedRemotePointers.remove(event.pointer)) return;
      if (_activeRemotePointer != event.pointer) return;
      final releaseAt = normalized ?? _lastRemotePointer;
      _activeRemotePointer = null;
      _lastRemotePointer = null;
      if (releaseAt != null) _sendPointer(releaseAt, 0);
      return;
    }
    if (_rejectedRemotePointers.contains(event.pointer) ||
        (widget.mode == RdpDisplayMode.native && _nativePanEnabled)) {
      return;
    }
    if (_activeRemotePointer != null && _activeRemotePointer != event.pointer) {
      return;
    }
    if (normalized == null) return;
    if (_activeRemotePointer == event.pointer) {
      _lastRemotePointer = normalized;
    }
    _sendPointer(normalized, event.buttons);
  }

  void _sendPointer(Offset normalized, int buttons) {
    final geometry = _displayedFrame?.geometry;
    if (geometry == null) return;
    widget.controller.pointer(
      RdpPointerEvent(
        x: normalized.dx,
        y: normalized.dy,
        buttons: buttons.clamp(0, 7),
        geometry: geometry,
      ),
    );
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final geometry = _displayedFrame?.geometry;
    if (geometry == null || event.scrollDelta.dy == 0) return;
    _wheelRemainder += event.scrollDelta.dy;
    const logicalPixelsPerStep = 20.0;
    final steps = (_wheelRemainder / logicalPixelsPerStep).truncate().clamp(
      -16,
      16,
    );
    if (steps == 0) return;
    _wheelRemainder -= steps * logicalPixelsPerStep;
    final delta = steps.isNegative ? 120 : -120;
    for (var index = 0; index < steps.abs(); index++) {
      widget.controller.wheel(
        RdpWheelEvent(wheelDelta: delta, geometry: geometry),
      );
    }
  }

  void _releaseRemotePointerForPan() {
    final pointer = _activeRemotePointer;
    final releaseAt = _lastRemotePointer;
    if (pointer == null || releaseAt == null) return;
    _rejectedRemotePointers.add(pointer);
    _activeRemotePointer = null;
    _lastRemotePointer = null;
    _sendPointer(releaseAt, 0);
  }

  void _panFrame(DragUpdateDetails details, Size size) {
    if (widget.mode != RdpDisplayMode.native || !_nativePanEnabled) return;
    final geometry = _geometry(size);
    if (geometry == null) return;
    final next = geometry.panAfterDrag(details.delta);
    if (next != _nativePan) setState(() => _nativePan = next);
  }

  void _toggleNativePan() {
    if (widget.mode != RdpDisplayMode.native) return;
    if (!_nativePanEnabled) _releaseRemotePointerForPan();
    setState(() => _nativePanEnabled = !_nativePanEnabled);
  }

  @override
  void dispose() {
    _frameGeneration++;
    unawaited(_frames?.cancel());
    _image?.dispose();
    _displayedFrame = null;
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth,
          widget.expand ? constraints.maxHeight : 480,
        );
        _resize(size);
        final geometry = _geometry(size);
        return Focus(
          key: const ValueKey('rdp-surface'),
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: Semantics(
            label: widget.label,
            focusable: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: CupertinoColors.black,
                  child: SizedBox(
                    height: size.height,
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: widget.mode == RdpDisplayMode.native
                                ? (details) => _panFrame(details, size)
                                : null,
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerSignal: _wheel,
                              onPointerDown: (event) {
                                _focus.requestFocus();
                                _pointer(event, size);
                              },
                              onPointerMove: (event) => _pointer(event, size),
                              onPointerUp: (event) => _pointer(event, size),
                              onPointerCancel: (event) => _pointer(event, size),
                              child: Stack(
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  if (geometry == null)
                                    Center(
                                      child: Icon(
                                        CupertinoIcons.desktopcomputer,
                                        size: 64,
                                        color: CupertinoColors.systemGrey
                                            .resolveFrom(context),
                                      ),
                                    )
                                  else
                                    Positioned.fromRect(
                                      rect: geometry.destination,
                                      child: ExcludeSemantics(
                                        child: RawImage(
                                          key: const ValueKey(
                                            'rdp-frame-image',
                                          ),
                                          image: _image,
                                          fit: BoxFit.fill,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (widget.mode == RdpDisplayMode.native &&
                            geometry != null)
                          PositionedDirectional(
                            top: 8,
                            end: 8,
                            child: Semantics(
                              button: true,
                              toggled: _nativePanEnabled,
                              label: _nativePanEnabled
                                  ? widget.panDisableLabel
                                  : widget.panEnableLabel,
                              child: SizedBox.square(
                                dimension: 48,
                                child: CupertinoButton(
                                  key: const ValueKey('rdp-native-pan'),
                                  padding: EdgeInsets.zero,
                                  color: CupertinoColors.systemGrey
                                      .resolveFrom(context)
                                      .withValues(alpha: .75),
                                  onPressed: _toggleNativePan,
                                  child: Icon(
                                    _nativePanEnabled
                                        ? CupertinoIcons.cursor_rays
                                        : CupertinoIcons.move,
                                    color: CupertinoColors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
