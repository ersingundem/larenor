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
import 'rdp_engine.dart';
import 'rdp_models.dart';
import 'rdp_security_store.dart';
import 'rdp_session_controller.dart';

final rdpEngineFactoryProvider = Provider<RdpEngine Function()>(
  (_) => UnsupportedRdpEngine.new,
);
final rdpTrustStoreProvider = Provider<RdpTrustStore>(
  (_) => RdpSecurityStore(),
);

class RdpSessionPanel extends ConsumerStatefulWidget {
  const RdpSessionPanel({
    super.key,
    required this.profile,
    required this.isCurrent,
    required this.onBack,
  });
  final RemoteProfile profile;
  final bool Function() isCurrent;
  final VoidCallback onBack;
  @override
  ConsumerState<RdpSessionPanel> createState() => _RdpSessionPanelState();
}

class _RdpSessionPanelState extends ConsumerState<RdpSessionPanel>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  ProviderContainer? _container;
  AppInteractionController? _interaction;
  RdpSessionController? _controller;
  RdpEngine Function()? _factory;
  RdpTrustStore? _trust;
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
          !identical(_factory, ref.read(rdpEngineFactoryProvider)) ||
          !identical(_trust, ref.read(rdpTrustStoreProvider))) {
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
    _trust ??= ref.read(rdpTrustStoreProvider);
    _controller ??= _newController()..addListener(_changed);
    if (!TickerMode.valuesOf(context).enabled) _retire();
  }

  RdpSessionController _newController() {
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
    return RdpSessionController(
      profile: widget.profile,
      trust: _trust!,
      engineFactory: _factory!,
      isCurrent: _current,
      display: RdpDisplaySpec(
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
      key: const ValueKey('rdp-session-panel'),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: CustomScrollView(
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
                          _status(l, c),
                          key: const ValueKey('rdp-status'),
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
                                l.rdpDisplay,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                l.rdpDisplayValue(
                                  c.display.width,
                                  c.display.height,
                                  c.display.dpi,
                                ),
                              ),
                              if (c.display.externalDisplay)
                                Text(l.rdpExternalDisplay),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.rdpClipboardOff),
                              Text(l.rdpAudioOff),
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
                            () => unawaited(c.connect()),
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
                              onSubmitted: (_) =>
                                  unawaited(c.authenticate(_password.text)),
                            ),
                          ),
                          action(
                            'rdp-authenticate',
                            l.rdpAuthenticate,
                            () => unawaited(c.authenticate(_password.text)),
                          ),
                        ],
                        if (c.phase == RdpSessionPhase.connected)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Semantics(
                              container: true,
                              label: l.rdpInputReady,
                              child: Text(l.rdpInputReady),
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
