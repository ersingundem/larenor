import 'dart:async';
import 'dart:math';
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
import 'rdp_schema6_controller.dart';
import 'rdp_schema6_engine.dart';
import 'rdp_schema6_models.dart';
import 'rdp_schema6_security_store.dart';
import 'rdp_schema6_session_authority.dart';
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
final rdpSchema6TransferPortProvider = Provider<RdpSchema6TransferPort>(
  (_) => RdpSchema6MethodChannelTransferPort(),
);
final rdpSchema6SessionOwnerFactoryProvider =
    Provider<RdpSchema6SessionOwner Function(int)>((_) {
      final random = Random.secure();
      return (revision) => RdpSchema6SessionOwner(
        requestId: _schema6Uuid(random),
        revision: revision,
      );
    });
final rdpSchema6SecretVaultProvider = Provider<RdpSchema6CurrentSecretVault>(
  (_) => RdpSchema6SecureSecretVault(),
);
final rdpGatewayEnrollmentEngineFactoryProvider =
    Provider<RdpGatewayEnrollmentEngine Function()>(
      (_) => RdpSchema6MethodChannelGatewayEngine.new,
    );

// UI admission comes from the product capability boundary, independently of
// the compiled package's support. Pending/error observations stay unavailable.
final rdpGatewayEnrollmentAdmittedProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  final engine = ref.watch(rdpEngineFactoryProvider)();
  var current = true;
  ref.onDispose(() {
    current = false;
    engine.close();
  });
  try {
    final capabilities = await engine.capabilities(isCurrent: () => current);
    return current && capabilities.canConnect && capabilities.supportsRdGateway;
  } catch (_) {
    return false;
  }
});

class RdpSessionPanel extends ConsumerStatefulWidget {
  const RdpSessionPanel({
    super.key,
    required this.profile,
    required this.authorityRevision,
    required this.isCurrent,
    required this.onBack,
    this.securityStore,
    this.coreSecurity,
    this.schema6TransferPort,
    this.schema6OwnerFactory,
    this.schema6Secrets,
    this.onMicrophonePermissionPromptChanged,
    this.onFileTransferPickerChanged,
  });
  final RemoteProfile profile;
  final int authorityRevision;
  final bool Function() isCurrent;
  final VoidCallback onBack;
  final RdpSecurityStore? securityStore;
  final RdpCoreSecurityProjection? coreSecurity;
  final RdpSchema6TransferPort? schema6TransferPort;
  final RdpSchema6SessionOwner Function(int revision)? schema6OwnerFactory;
  final RdpSchema6CurrentSecretVault? schema6Secrets;
  final ValueChanged<bool>? onMicrophonePermissionPromptChanged;
  final ValueChanged<bool>? onFileTransferPickerChanged;
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
  RdpSchema6TransferPort? _transferPort;
  RdpSchema6SessionOwner Function(int)? _schema6OwnerFactory;
  RdpSchema6CurrentSecretVault? _schema6Secrets;
  RdpProfileSettings _settings = const RdpProfileSettings();
  bool _settingsStarted = false, _settingsLoaded = false, _settingsBusy = false;
  bool _rememberCredential = false;
  String? _settingsNotice;
  bool _resumed = true, _focused = true, _retired = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
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
  bool _reportedMicrophonePermissionPrompt = false;
  bool _reportedFileTransferPicker = false;
  bool _fileTransferBusy = false;
  RdpFileTransferGrantState? _fileTransferGrantState;
  bool _fileTransferSessionBusy = false;
  RdpTransferState? _fileTransferSessionState;

  void _reportMicrophonePermissionPrompt(bool value) {
    if (_reportedMicrophonePermissionPrompt == value) return;
    _reportedMicrophonePermissionPrompt = value;
    widget.onMicrophonePermissionPromptChanged?.call(value);
  }

  void _reportFileTransferPicker(bool value) {
    if (_reportedFileTransferPicker == value) return;
    _reportedFileTransferPicker = value;
    widget.onFileTransferPickerChanged?.call(value);
  }

  WindowDisplayIdentity? _loadedDisplayIdentity() {
    final state = ref.read(windowPolicySnapshotProvider);
    if (!state.hasValue || state.isLoading || state.hasError) return null;
    return state.requireValue.displayIdentity;
  }

  bool _current({
    bool allowMicrophonePrompt = false,
    bool allowFileTransferPicker = false,
  }) {
    try {
      final ownsPermissionPrompt =
          allowMicrophonePrompt &&
          _controller?.microphonePermissionPending == true &&
          _lifecycleState == AppLifecycleState.inactive;
      final ownsFileTransferPicker =
          allowFileTransferPicker &&
          _controller?.fileTransferPickerPending == true &&
          _lifecycleState != AppLifecycleState.detached;
      final ownsNativePrompt = ownsPermissionPrompt || ownsFileTransferPicker;
      if (_retired ||
          !mounted ||
          (!_resumed && !ownsNativePrompt) ||
          (!_focused && !ownsNativePrompt) ||
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
          ) ||
          !identical(
            _transferPort,
            widget.schema6TransferPort ??
                ref.read(rdpSchema6TransferPortProvider),
          ) ||
          !identical(
            _schema6OwnerFactory,
            widget.schema6OwnerFactory ??
                ref.read(rdpSchema6SessionOwnerFactoryProvider),
          ) ||
          !identical(
            _schema6Secrets,
            widget.schema6Secrets ?? ref.read(rdpSchema6SecretVaultProvider),
          )) {
        return false;
      }
      final state = ref.read(windowPolicySnapshotProvider);
      if (!state.hasValue || state.isLoading || state.hasError) return false;
      final value = state.requireValue;
      return !value.supported ||
          (value.isResumed || ownsNativePrompt) &&
              (value.hasWindowFocus || ownsNativePrompt) &&
              !value.isPictureInPicture;
    } catch (_) {
      return false;
    }
  }

  bool get _ownsNativePromptLifecycle =>
      _controller?.fileTransferPickerPending == true &&
          _lifecycleState != AppLifecycleState.detached ||
      _controller?.microphonePermissionPending == true &&
          _lifecycleState == AppLifecycleState.inactive;

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
    _transferPort ??=
        widget.schema6TransferPort ?? ref.read(rdpSchema6TransferPortProvider);
    _schema6OwnerFactory ??=
        widget.schema6OwnerFactory ??
        ref.read(rdpSchema6SessionOwnerFactoryProvider);
    _schema6Secrets ??=
        widget.schema6Secrets ?? ref.read(rdpSchema6SecretVaultProvider);
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
        !identical(oldWidget.profile, widget.profile) ||
        oldWidget.coreSecurity != widget.coreSecurity ||
        !identical(oldWidget.schema6TransferPort, widget.schema6TransferPort) ||
        !identical(oldWidget.schema6OwnerFactory, widget.schema6OwnerFactory) ||
        !identical(oldWidget.schema6Secrets, widget.schema6Secrets)) {
      _retire();
    }
  }

  RdpSessionController _newController({
    required WindowDisplayIdentity? displayIdentity,
  }) {
    _controllerDisplayIdentity = displayIdentity;
    final media = MediaQuery.of(context), size = media.size;
    final grant = _settings.fileTransferGrant;
    final transfer = grant == null
        ? null
        : RdpSchema6TransferCoordinator(
            port: _transferPort!,
            authority: _fileTransferAuthority(),
            grant: grant,
            isCurrent: _current,
          );
    final schema6 = transfer != null
        ? RdpSchema6SessionAuthority(transfer: transfer, isCurrent: _current)
        : widget.coreSecurity?.gateway != null
        ? RdpSchema6SessionAuthority.gatewayOnly(isCurrent: _current)
        : null;
    return RdpSessionController(
      profile: widget.profile,
      trust: _trust!,
      credentialVault: _security,
      engineFactory: _factory!,
      isCurrent: () =>
          _current(
            allowMicrophonePrompt: true,
            allowFileTransferPicker: true,
          ) &&
          displayIdentity != null &&
          _loadedDisplayIdentity() == displayIdentity,
      isInteractive: _current,
      display: RdpDisplaySpec.fromViewport(
        widthPixels: (size.width * media.devicePixelRatio).round(),
        heightPixels: (size.height * media.devicePixelRatio).round(),
        devicePixelRatio: media.devicePixelRatio,
        externalDisplay: displayIdentity?.isExternalDisplay ?? false,
      ),
      settings: _settings,
      authoritativeSecurity: widget.coreSecurity,
      schema6Authority: schema6,
      schema6OwnerFactory: schema6 == null ? null : _schema6OwnerFactory,
      schema6Secrets: widget.coreSecurity?.gateway == null
          ? null
          : _schema6Secrets,
      schema6SecretScope: widget.coreSecurity?.gateway == null
          ? null
          : _schema6SecretScope(),
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

  RdpProfileSettings _applyCoreSecurity(RdpProfileSettings value) {
    final security = widget.coreSecurity;
    if (security == null) return value;
    final gateway = security.gateway?.endpoint;
    return RdpProfileSettings(
      domain: security.domain,
      gatewayHost: gateway?.host,
      gatewayPort: gateway?.port ?? 443,
      gatewayUsername: gateway?.username ?? '',
      gatewayDomain: gateway?.domain ?? '',
      displayMode: value.displayMode,
      keyboardLayout: value.keyboardLayout,
      clipboardMode: value.clipboardMode,
      microphone: value.microphone,
      fileTransferGrant: value.fileTransferGrant,
    );
  }

  Future<void> _loadSettings() async {
    if (!_current()) return;
    try {
      final stored = await _security!.readSettings(
        widget.profile,
        isCurrent: _current,
      );
      if (!_current()) return;
      final value = _applyCoreSecurity(stored);
      _settings = value;
      _fillSettings(value);
      _settingsLoaded = true;
      _replaceController(
        displayIdentity: _loadedDisplayIdentity(),
        force: true,
      );
      if (value.fileTransferGrant != null) {
        unawaited(_reconcileFileTransferGrant());
      } else {
        _fileTransferGrantState = null;
      }
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
    if (_settings.fileTransferGrant != null &&
        _fileTransferGrantState != RdpFileTransferGrantState.active) {
      _settingsNotice = 'failed';
      if (mounted) setState(() {});
      return;
    }
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
      final security = widget.coreSecurity;
      final gateway = security?.gateway?.endpoint;
      final enteredGateway = _gatewayHost.text.trim();
      final value = RdpProfileSettings(
        domain: security?.domain ?? _domain.text.trim(),
        gatewayHost:
            gateway?.host ??
            (enteredGateway.isEmpty
                ? null
                : normalizeRemoteHost(enteredGateway)),
        gatewayPort: gateway?.port ?? int.tryParse(_gatewayPort.text) ?? -1,
        gatewayUsername: gateway?.username ?? _gatewayUser.text.trim(),
        gatewayDomain: gateway?.domain ?? _settings.gatewayDomain,
        displayMode: _settings.displayMode,
        keyboardLayout: _settings.keyboardLayout,
        clipboardMode: _settings.clipboardMode,
        microphone: _settings.microphone,
        fileTransferGrant: _settings.fileTransferGrant,
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

  RdpFileTransferAuthority _fileTransferAuthority() =>
      _security!.fileTransferAuthority(
        widget.profile,
        profileRevision: widget.authorityRevision,
      );

  RdpSchema6SecretScope _schema6SecretScope() {
    final authority = _fileTransferAuthority();
    return RdpSchema6SecretScope(
      namespaceDigest: authority.namespaceDigest,
      profileRef: authority.profileRef,
      profileRevision: authority.profileRevision,
    );
  }

  Future<void> _reconcileFileTransferGrant() async {
    final controller = _controller;
    final grant = _settings.fileTransferGrant;
    if (!_current() ||
        controller == null ||
        grant == null ||
        _fileTransferBusy ||
        controller.phase != RdpSessionPhase.idle) {
      return;
    }
    final authority = _fileTransferAuthority();
    _fileTransferBusy = true;
    if (mounted) setState(() {});
    try {
      var observed = await controller.observeFileTransferGrant(
        authority,
        grant,
      );
      if (!_current() || !identical(controller, _controller)) return;
      if (observed.state == RdpFileTransferGrantState.prepared) {
        observed = await controller.activateFileTransferGrant(authority, grant);
        if (!_current() || !identical(controller, _controller)) return;
      }
      _fileTransferGrantState = observed.state;
    } catch (_) {
      if (_current() && identical(controller, _controller)) {
        _fileTransferGrantState = RdpFileTransferGrantState.unknown;
      }
    } finally {
      _fileTransferBusy = false;
      if (_current() && mounted) setState(() {});
    }
  }

  Future<void> _selectFileTransferTree() async {
    final controller = _controller;
    if (!_current() ||
        controller == null ||
        controller.phase != RdpSessionPhase.idle ||
        !_settingsLoaded ||
        _settings.fileTransferGrant != null ||
        _fileTransferBusy) {
      return;
    }
    final authority = _fileTransferAuthority();
    _fileTransferBusy = true;
    _fileTransferGrantState = null;
    if (mounted) setState(() {});
    RdpFileTransferGrantObservation? prepared;
    try {
      prepared = await controller.selectFileTransferTree(authority);
      if (!_current() || !identical(controller, _controller)) return;
      final next = _settings.copyWith(fileTransferGrant: prepared.grant);
      await _security!.saveSettings(
        widget.profile,
        next,
        isCurrent: () =>
            _current(
              allowFileTransferPicker: true,
              allowMicrophonePrompt: true,
            ) &&
            identical(controller, _controller),
      );
      if (!_current() || !identical(controller, _controller)) return;
      _settings = next;
      _fileTransferGrantState = RdpFileTransferGrantState.prepared;
      final active = await controller.activateFileTransferGrant(
        authority,
        prepared.grant,
      );
      if (!_current() || !identical(controller, _controller)) return;
      _fileTransferGrantState = active.state;
      _replaceController(
        displayIdentity: _loadedDisplayIdentity(),
        force: true,
      );
    } catch (_) {
      if (prepared != null && _settings.fileTransferGrant != prepared.grant) {
        try {
          await controller.retireFileTransferGrant(authority, prepared.grant);
        } catch (_) {
          // Native prepared expiry and observation preserve the unknown fence.
        }
      }
      if (_current() && identical(controller, _controller)) {
        _fileTransferGrantState = prepared == null
            ? null
            : RdpFileTransferGrantState.unknown;
        _settingsNotice = 'failed';
      }
    } finally {
      _fileTransferBusy = false;
      if (_current() && mounted) setState(() {});
    }
  }

  Future<void> _removeFileTransferGrant() async {
    final controller = _controller;
    final grant = _settings.fileTransferGrant;
    if (!_current() ||
        controller == null ||
        grant == null ||
        controller.phase != RdpSessionPhase.idle ||
        _fileTransferBusy) {
      return;
    }
    final authority = _fileTransferAuthority();
    _fileTransferBusy = true;
    if (mounted) setState(() {});
    try {
      final retired = await controller.retireFileTransferGrant(
        authority,
        grant,
      );
      if (!_current() ||
          !identical(controller, _controller) ||
          retired.state != RdpFileTransferGrantState.retired) {
        return;
      }
      _fileTransferGrantState = RdpFileTransferGrantState.retired;
      final next = _settings.copyWith(fileTransferGrant: null);
      await _security!.saveSettings(
        widget.profile,
        next,
        isCurrent: () => _current() && identical(controller, _controller),
      );
      if (!_current() || !identical(controller, _controller)) return;
      _settings = next;
      _fileTransferGrantState = null;
      _replaceController(
        displayIdentity: _loadedDisplayIdentity(),
        force: true,
      );
    } catch (_) {
      if (_current() && identical(controller, _controller)) {
        _settingsNotice = 'failed';
      }
    } finally {
      _fileTransferBusy = false;
      if (_current() && mounted) setState(() {});
    }
  }

  Future<void> _observeFileTransferSession() async {
    final controller = _controller;
    if (!_current() ||
        controller == null ||
        _fileTransferSessionBusy ||
        controller.fileTransferReceipt == null) {
      return;
    }
    _fileTransferSessionBusy = true;
    if (mounted) setState(() {});
    try {
      final observed = await controller.observeFileTransferSession();
      if (!_current() || !identical(controller, _controller)) return;
      _fileTransferSessionState = observed?.state;
    } catch (_) {
      if (_current() && identical(controller, _controller)) {
        _fileTransferSessionState = RdpTransferState.unknown;
        _settingsNotice = 'failed';
      }
    } finally {
      _fileTransferSessionBusy = false;
      if (_current() && mounted) setState(() {});
    }
  }

  Future<void> _saveReceivedFiles() async {
    final controller = _controller;
    if (!_current() ||
        controller == null ||
        _fileTransferSessionBusy ||
        controller.fileTransferReceipt?.state != RdpTransferState.sealed) {
      return;
    }
    _fileTransferSessionBusy = true;
    if (mounted) setState(() {});
    try {
      final saved = await controller.saveReceivedFiles();
      if (!_current() || !identical(controller, _controller)) return;
      _fileTransferSessionState = saved?.state;
      if (saved?.state == RdpTransferState.saved) {
        _replaceController(
          displayIdentity: _loadedDisplayIdentity(),
          force: true,
        );
      }
    } catch (_) {
      if (_current() && identical(controller, _controller)) {
        _fileTransferSessionState = RdpTransferState.unknown;
        _settingsNotice = 'failed';
      }
    } finally {
      _fileTransferSessionBusy = false;
      if (_current() && mounted) setState(() {});
    }
  }

  void _changed() {
    if (!mounted) return;
    _reportMicrophonePermissionPrompt(
      _controller?.microphonePermissionPending == true,
    );
    _reportFileTransferPicker(_controller?.fileTransferPickerPending == true);
    final phase = _controller?.phase;
    _fileTransferSessionState = _controller?.fileTransferReceipt?.state;
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
    if (!_current(allowMicrophonePrompt: true, allowFileTransferPicker: true)) {
      _retire();
    }
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _reportMicrophonePermissionPrompt(false);
    _reportFileTransferPicker(false);
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
    _lifecycleState = state;
    _resumed = state == AppLifecycleState.resumed;
    final ownsMicrophonePrompt =
        state == AppLifecycleState.inactive &&
        _controller?.microphonePermissionPending == true;
    final ownsFileTransferPicker =
        state != AppLifecycleState.detached &&
        _controller?.fileTransferPickerPending == true;
    if (!_resumed && !ownsMicrophonePrompt && !ownsFileTransferPicker) {
      _retire();
    }
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (event.viewId != View.of(context).viewId) return;
    _focused = event.state == ui.ViewFocusState.focused;
    if (_focused) {
      _controller?.resumeMicrophonePermission();
      _controller?.resumeFileTransferPicker();
    } else if (_controller?.microphonePermissionPending != true &&
        _controller?.fileTransferPickerPending != true) {
      _retire();
    }
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
              ((!value.isResumed && !_ownsNativePromptLifecycle) ||
                  !value.hasWindowFocus && !_ownsNativePromptLifecycle ||
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
      bool editable = true,
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
            enabled: editable && _current() && !_settingsBusy,
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
                        field(
                          'rdp-settings-domain',
                          l.rdpDomain,
                          _domain,
                          editable: widget.coreSecurity == null,
                        ),
                        field(
                          'rdp-settings-gateway-host',
                          l.rdpGatewayHost,
                          _gatewayHost,
                          editable: widget.coreSecurity == null,
                          type: TextInputType.url,
                        ),
                        field(
                          'rdp-settings-gateway-port',
                          l.rdpGatewayPort,
                          _gatewayPort,
                          type: TextInputType.number,
                          editable: widget.coreSecurity == null,
                        ),
                        field(
                          'rdp-settings-gateway-user',
                          l.rdpGatewayUsername,
                          _gatewayUser,
                          editable: widget.coreSecurity == null,
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
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      Localizations.localeOf(context)
                                                  .languageCode ==
                                              'tr'
                                          ? 'Mikrofon yönlendirmesi'
                                          : 'Microphone redirection',
                                    ),
                                  ),
                                  CupertinoSwitch(
                                    key: const ValueKey(
                                      'rdp-microphone-enable',
                                    ),
                                    value: _settings.microphone,
                                    onChanged:
                                        _current() &&
                                            _settingsLoaded &&
                                            !_settingsBusy &&
                                            (_settings.microphone ||
                                                c
                                                        .capabilities
                                                        ?.supportsMicrophone !=
                                                    false)
                                        ? (value) => setState(
                                            () => _settings = _settings
                                                .copyWith(microphone: value),
                                          )
                                        : null,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                Localizations.localeOf(context).languageCode ==
                                        'tr'
                                    ? 'Bağlanırken Android mikrofon izni istenir. Yalnızca açıkça etkinleştirilen oturum yakalama başlatabilir.'
                                    : 'Android microphone permission is requested when connecting. Capture can start only for an explicitly enabled session.',
                              ),
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
                        Padding(
                          key: const ValueKey('rdp-file-transfer-boundary'),
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '${switch (_fileTransferGrantState) {
                              RdpFileTransferGrantState.active => Localizations.localeOf(context).languageCode == 'tr' ? 'Klasör izni doğrulandı.' : 'Folder permission is verified.',
                              RdpFileTransferGrantState.prepared => Localizations.localeOf(context).languageCode == 'tr' ? 'Klasör izni doğrulanmayı bekliyor.' : 'Folder permission is awaiting verification.',
                              RdpFileTransferGrantState.retired => Localizations.localeOf(context).languageCode == 'tr' ? 'Klasör izni kaldırıldı; kayıtlı başvuruyu temizleyin.' : 'Folder permission was removed; clear the saved reference.',
                              RdpFileTransferGrantState.unknown => Localizations.localeOf(context).languageCode == 'tr' ? 'Klasör izni güvenle doğrulanamadı.' : 'Folder permission could not be verified safely.',
                              null => Localizations.localeOf(context).languageCode == 'tr' ? 'Aktarım klasörü seçilmedi.' : 'No transfer folder is selected.',
                            }} '
                            '${c.capabilities?.supportsFiles == true && _fileTransferGrantState == RdpFileTransferGrantState.active
                                ? Localizations.localeOf(context).languageCode == 'tr'
                                      ? 'Bu izin yalnızca sonraki açık RDP oturumunun özel aynasını hazırlar; sağlayıcıya yazma ayrıca onaylanır.'
                                      : 'This grant prepares only the next explicit RDP session mirror; writing to the provider requires separate confirmation.'
                                : Localizations.localeOf(context).languageCode == 'tr'
                                ? 'Bu seçim yalnızca klasör iznini hazırlar; paketlenmiş RDP dosya paylaşımı henüz doğrulanmadı.'
                                : 'This only prepares folder permission; packaged RDP file sharing is not verified yet.'}',
                          ),
                        ),
                        action(
                          _settings.fileTransferGrant == null
                              ? 'rdp-file-transfer-select'
                              : 'rdp-file-transfer-remove',
                          _settings.fileTransferGrant == null
                              ? (Localizations.localeOf(context).languageCode ==
                                        'tr'
                                    ? 'Aktarım klasörü seç'
                                    : 'Choose transfer folder')
                              : (Localizations.localeOf(context).languageCode ==
                                        'tr'
                                    ? 'Klasör iznini kaldır'
                                    : 'Remove folder permission'),
                          !_settingsLoaded ||
                                  _fileTransferBusy ||
                                  c.phase != RdpSessionPhase.idle
                              ? null
                              : _settings.fileTransferGrant == null
                              ? () => unawaited(_selectFileTransferTree())
                              : () => unawaited(_removeFileTransferGrant()),
                        ),
                        if (_fileTransferSessionState case final state?) ...[
                          Padding(
                            key: const ValueKey(
                              'rdp-file-transfer-session-state',
                            ),
                            padding: const EdgeInsets.all(20),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(switch (state) {
                                RdpTransferState.prepared ||
                                RdpTransferState.active =>
                                  Localizations.localeOf(context)
                                              .languageCode ==
                                          'tr'
                                      ? 'Dosya aktarımı hâlâ özel çalışma alanında etkin.'
                                      : 'File transfer is still active in the private workspace.',
                                RdpTransferState.sealed =>
                                  Localizations.localeOf(context)
                                              .languageCode ==
                                          'tr'
                                      ? 'Yerel aktarım kapandı. Alınan dosyalar yalnız açık Kaydet eylemiyle seçili klasöre yazılır.'
                                      : 'The local transfer is closed. Received files are written to the selected folder only by an explicit Save action.',
                                RdpTransferState.saved =>
                                  Localizations.localeOf(context)
                                              .languageCode ==
                                          'tr'
                                      ? 'Alınan dosyaların boyut ve özet doğrulaması tamamlandı.'
                                      : 'Received file size and digest verification completed.',
                                RdpTransferState.unknown =>
                                  Localizations.localeOf(context)
                                              .languageCode ==
                                          'tr'
                                      ? 'Aktarımın kapanış sonucu bilinmiyor. Yeni oturum engellendi; yeniden göndermeden durumu denetleyin.'
                                      : 'The transfer close outcome is unknown. A new session is blocked; check status without replaying it.',
                              }),
                            ),
                          ),
                          if (state == RdpTransferState.sealed)
                            action(
                              'rdp-file-transfer-save-received',
                              Localizations.localeOf(context).languageCode ==
                                      'tr'
                                  ? 'Alınan dosyaları kaydet'
                                  : 'Save received files',
                              _fileTransferSessionBusy
                                  ? null
                                  : () => unawaited(_saveReceivedFiles()),
                            ),
                          if (state == RdpTransferState.unknown)
                            action(
                              'rdp-file-transfer-check-session',
                              Localizations.localeOf(context).languageCode ==
                                      'tr'
                                  ? 'Aktarım durumunu denetle'
                                  : 'Check transfer status',
                              _fileTransferSessionBusy
                                  ? null
                                  : () => unawaited(
                                      _observeFileTransferSession(),
                                    ),
                            ),
                        ],
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
                              Text(
                                !_settings.microphone
                                    ? Localizations.localeOf(context)
                                                  .languageCode ==
                                              'tr'
                                          ? 'Mikrofon kapalı'
                                          : 'Microphone off'
                                    : c.microphonePermissionPending
                                    ? Localizations.localeOf(context)
                                                  .languageCode ==
                                              'tr'
                                          ? 'Mikrofon izni bekleniyor'
                                          : 'Waiting for microphone permission'
                                    : switch (c.microphoneObservation?.state) {
                                        RdpMicrophoneState.opened =>
                                          Localizations.localeOf(context)
                                                      .languageCode ==
                                                  'tr'
                                              ? 'Mikrofon açık; ses bekleniyor'
                                              : 'Microphone open; waiting for audio',
                                        RdpMicrophoneState.captured =>
                                          Localizations.localeOf(context)
                                                      .languageCode ==
                                                  'tr'
                                              ? 'Mikrofon sesi yakalandı'
                                              : 'Microphone audio captured',
                                        RdpMicrophoneState.sent =>
                                          Localizations.localeOf(context)
                                                      .languageCode ==
                                                  'tr'
                                              ? 'Mikrofon sesi uzak kanala gönderildi'
                                              : 'Microphone audio sent to the remote channel',
                                        RdpMicrophoneState.closed =>
                                          Localizations.localeOf(context)
                                                      .languageCode ==
                                                  'tr'
                                              ? 'Mikrofon kanalı kapandı'
                                              : 'Microphone channel closed',
                                        RdpMicrophoneState.failed =>
                                          Localizations.localeOf(context)
                                                      .languageCode ==
                                                  'tr'
                                              ? 'Mikrofon kullanılamıyor'
                                              : 'Microphone unavailable',
                                        _ =>
                                          c.phase == RdpSessionPhase.failed ||
                                                  c.phase ==
                                                      RdpSessionPhase
                                                          .unsupported
                                              ? Localizations.localeOf(context)
                                                            .languageCode ==
                                                        'tr'
                                                    ? 'Mikrofon kullanılamıyor'
                                                    : 'Microphone unavailable'
                                              : Localizations.localeOf(context)
                                                        .languageCode ==
                                                    'tr'
                                              ? 'Mikrofon etkin; bağlantı bekleniyor'
                                              : 'Microphone enabled; waiting for the session',
                                      },
                                key: const ValueKey('rdp-microphone-status'),
                              ),
                              Semantics(
                                liveRegion: true,
                                child: Text(switch (_fileTransferSessionState) {
                                  RdpTransferState.prepared =>
                                    l.rdpFilesPrepared,
                                  RdpTransferState.active => l.rdpFilesActive,
                                  RdpTransferState.sealed => l.rdpFilesSealed,
                                  RdpTransferState.saved => l.rdpFilesSaved,
                                  RdpTransferState.unknown => l.rdpFilesUnknown,
                                  null => l.rdpFilesOff,
                                }, key: const ValueKey('rdp-files-status')),
                              ),
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

String _schema6Uuid(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final encoded = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${encoded.substring(0, 8)}-${encoded.substring(8, 12)}-'
      '${encoded.substring(12, 16)}-${encoded.substring(16, 20)}-'
      '${encoded.substring(20)}';
}
