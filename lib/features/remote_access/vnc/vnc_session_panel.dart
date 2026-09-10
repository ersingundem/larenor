import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/remote_profiles.dart';
import 'vnc_engine.dart';
import 'vnc_models.dart';
import 'vnc_security_store.dart';
import 'vnc_session_controller.dart';

final vncEngineFactoryProvider = Provider<VncEngine Function()>(
  (_) => UnsupportedVncEngine.new,
);
final vncTrustStoreProvider = Provider<VncTrustStore>(
  (_) => VncSecurityStore(),
);

class VncSessionPanel extends ConsumerStatefulWidget {
  const VncSessionPanel({
    super.key,
    required this.profile,
    required this.isCurrent,
    required this.onBack,
  });
  final RemoteProfile profile;
  final bool Function() isCurrent;
  final VoidCallback onBack;
  @override
  ConsumerState<VncSessionPanel> createState() => _VncSessionPanelState();
}

class _VncSessionPanelState extends ConsumerState<VncSessionPanel>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  ProviderContainer? _container;
  AppInteractionController? _interaction;
  VncSessionController? _controller;
  VncEngine Function()? _factory;
  VncTrustStore? _trust;
  bool _resumed = true, _focused = true, _retired = false;

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
          !identical(_factory, ref.read(vncEngineFactoryProvider)) ||
          !identical(_trust, ref.read(vncTrustStoreProvider))) {
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
    _factory ??= ref.read(vncEngineFactoryProvider);
    _trust ??= ref.read(vncTrustStoreProvider);
    _controller ??= _newController()..addListener(_changed);
    if (!TickerMode.valuesOf(context).enabled) _retire();
  }

  VncSessionController _newController() {
    final media = MediaQuery.of(context), size = media.size;
    var width = (size.width * media.devicePixelRatio).round().clamp(640, 8192),
        height = (size.height * media.devicePixelRatio).round().clamp(
          480,
          8192,
        );
    while (width * height > 33554432) {
      width = (width * .9).round();
      height = (height * .9).round();
    }
    final window = ref.read(windowPolicySnapshotProvider).value;
    return VncSessionController(
      profile: widget.profile,
      trust: _trust!,
      engineFactory: _factory!,
      isCurrent: _current,
      display: VncDisplaySpec(
        width: width,
        height: height,
        dpi: (160 * media.devicePixelRatio).round().clamp(72, 640),
        externalDisplay: window?.isExternalDisplay == true,
      ),
    );
  }

  void _changed() {
    if (!mounted) return;
    if (_controller?.hasSensitiveInput != true) _password.clear();
    setState(() {});
  }

  void _ownerChanged() {
    if (!_current()) _retire();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _password.clear();
    _controller?.retire();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _retire();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != View.of(context).viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _retire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_ownerChanged);
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _password.dispose();
    super.dispose();
  }

  String _status(AppLocalizations l, VncSessionController c) =>
      switch (c.phase) {
        VncSessionPhase.idle => l.vncProfileHint,
        VncSessionPhase.checking => l.vncChecking,
        VncSessionPhase.unsupported => l.vncEngineUnavailable,
        VncSessionPhase.certificate => l.vncCertificateReview,
        VncSessionPhase.passwordRequired => l.vncPassword,
        VncSessionPhase.connecting => l.vncConnecting,
        VncSessionPhase.connected => l.vncConnected,
        VncSessionPhase.closed => l.vncClosed,
        VncSessionPhase.failed => switch (c.error) {
          'plain_vnc_rejected' => l.vncPlainRejected,
          'no_auth_rejected' => l.vncNoAuthRejected,
          'security_unsupported' => l.vncSecurityUnsupported,
          'certificate_changed' => l.vncCertificateChanged,
          _ => l.vncFailed,
        },
      };

  @override
  Widget build(BuildContext context) {
    ref.listen(windowPolicySnapshotProvider, (_, next) {
      final value = next.value;
      if (next.isLoading ||
          next.hasError ||
          value == null ||
          value.supported &&
              (!value.isResumed ||
                  !value.hasWindowFocus ||
                  value.isPictureInPicture)) {
        _retire();
      }
    });
    ref.watch(windowPolicySnapshotProvider);
    final l = AppLocalizations.of(context), c = _controller!;
    Widget action(String key, String title, VoidCallback? callback) =>
        SettingsActionTile(
          key: ValueKey(key),
          title: Text(title),
          onTap: !_current() || callback == null ? null : callback,
        );
    return AppPageScaffold(
      key: const ValueKey('vnc-session-panel'),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: CustomScrollView(
              slivers: [
                CupertinoSliverNavigationBar(
                  leading: CupertinoButton(
                    key: const ValueKey('vnc-back'),
                    minimumSize: const Size(48, 48),
                    padding: EdgeInsets.zero,
                    onPressed: _current() ? widget.onBack : null,
                    child: const Icon(CupertinoIcons.back),
                  ),
                  largeTitle: Text(l.vncTitle),
                ),
                SliverList(
                  delegate: SliverChildListDelegate([
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _status(l, c),
                          key: const ValueKey('vnc-status'),
                        ),
                      ),
                    ),
                    SettingsSection(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.vncDisplay,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                l.vncDisplayValue(
                                  c.display.width,
                                  c.display.height,
                                  c.display.dpi,
                                ),
                              ),
                              if (c.display.externalDisplay)
                                Text(l.vncExternalDisplay),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.vncClipboardOff),
                              Text(l.vncFilesOff),
                              const SizedBox(height: 8),
                              Text(l.vncChannelsHint),
                            ],
                          ),
                        ),
                        if (c.phase == VncSessionPhase.idle)
                          action(
                            'vnc-check',
                            l.vncCheck,
                            () => unawaited(c.connect()),
                          ),
                        if (c.phase == VncSessionPhase.certificate) ...[
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: SelectableText(
                              c.pendingCertificate!.fingerprint,
                            ),
                          ),
                          action(
                            'vnc-trust',
                            l.vncTrustCertificate,
                            () => unawaited(c.trustCertificate()),
                          ),
                        ],
                        if (c.phase == VncSessionPhase.passwordRequired) ...[
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: CupertinoTextField(
                              key: const ValueKey('vnc-password'),
                              controller: _password,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              maxLength: 4096,
                              placeholder: l.vncPassword,
                              padding: const EdgeInsets.all(14),
                              onSubmitted: (_) =>
                                  unawaited(c.authenticate(_password.text)),
                            ),
                          ),
                          action(
                            'vnc-authenticate',
                            l.vncAuthenticate,
                            () => unawaited(c.authenticate(_password.text)),
                          ),
                        ],
                        if (c.phase == VncSessionPhase.connected)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Semantics(
                              container: true,
                              label: l.vncInputReady,
                              child: Text(l.vncInputReady),
                            ),
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
