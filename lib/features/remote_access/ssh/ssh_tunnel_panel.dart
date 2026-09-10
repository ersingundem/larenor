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
import 'ssh_terminal_panel.dart' show sshSecurityStoreProvider;
import 'ssh_tunnel_controller.dart';
import 'ssh_tunnel_engine.dart';
import 'ssh_tunnel_models.dart';

final sshTunnelEngineFactoryProvider = Provider<SshTunnelEngine Function()>(
  (_) => DartSshTunnelEngine.new,
);

class SshTunnelPanel extends ConsumerStatefulWidget {
  const SshTunnelPanel({
    super.key,
    required this.profile,
    required this.isCurrent,
    required this.onBack,
  });
  final RemoteProfile profile;
  final bool Function() isCurrent;
  final VoidCallback onBack;
  @override
  ConsumerState<SshTunnelPanel> createState() => _SshTunnelPanelState();
}

class _SshTunnelPanelState extends ConsumerState<SshTunnelPanel>
    with WidgetsBindingObserver {
  final _name = TextEditingController(),
      _local = TextEditingController(),
      _host = TextEditingController(),
      _remote = TextEditingController();
  AppInteractionController? _interaction;
  SshTunnelController? _controller;
  bool _resumed = true, _focused = true, _retired = false, _populated = false;
  String? _formError;

  bool _current() {
    try {
      final window = ref.read(windowPolicySnapshotProvider).value;
      return mounted &&
          !_retired &&
          _resumed &&
          _focused &&
          widget.isCurrent() &&
          _interaction?.active != false &&
          ModalRoute.of(context)?.isCurrent == true &&
          TickerMode.valuesOf(context).enabled &&
          window != null &&
          (!window.supported ||
              (window.isResumed &&
                  window.hasWindowFocus &&
                  !window.isPictureInPicture));
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
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_ownerChanged);
      _interaction = next;
      next?.addListener(_ownerChanged);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _retire();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (mounted && event.viewId == View.of(context).viewId) {
      _focused = event.state == ViewFocusState.focused;
      if (!_focused) _retire();
    }
  }

  void _ownerChanged() {
    if (!_current()) _retire();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _controller?.retire();
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    final value = _controller?.tunnel;
    if (!_populated && value != null) {
      _populated = true;
      _name.text = value.name;
      _local.text = '${value.localPort}';
      _host.text = value.targetHost;
      _remote.text = '${value.targetPort}';
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _save() async {
    try {
      final value = SshTunnelProfile.parse(
        name: _name.text,
        localPort: _local.text,
        targetHost: _host.text,
        targetPort: _remote.text,
      );
      setState(() => _formError = null);
      await _controller!.save(value);
    } catch (_) {
      if (mounted) setState(() => _formError = 'invalid');
    }
  }

  @override
  void dispose() {
    _retired = true;
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_ownerChanged);
    _controller?.removeListener(_changed);
    _controller?.dispose();
    for (final field in [_name, _local, _host, _remote]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final store = ref.watch(sshSecurityStoreProvider);
    final factory = ref.watch(sshTunnelEngineFactoryProvider);
    _controller ??= SshTunnelController(
      profile: widget.profile,
      store: store,
      engineFactory: factory,
      isCurrent: _current,
    )..addListener(_changed);
    if (_controller!.phase == SshTunnelPhase.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current() && _controller!.phase == SshTunnelPhase.idle) {
          unawaited(_controller!.load());
        }
      });
    }
    ref.listen(windowPolicySnapshotProvider, (_, next) {
      final w = next.value;
      if (w != null &&
          w.supported &&
          (!w.isResumed || !w.hasWindowFocus || w.isPictureInPicture)) {
        _retire();
      }
    });
    ref.watch(windowPolicySnapshotProvider);
    final c = _controller!, active = _current();
    Widget action(
      String key,
      String text,
      VoidCallback callback, {
      bool enabled = true,
    }) => SettingsActionTile(
      key: ValueKey(key),
      title: Text(text),
      onTap: active && enabled ? callback : null,
    );
    Widget field(
      String key,
      String text,
      TextEditingController controller, {
      bool number = false,
    }) => Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          const SizedBox(height: 6),
          CupertinoTextField(
            key: ValueKey(key),
            controller: controller,
            padding: const EdgeInsets.all(14),
            keyboardType: number ? TextInputType.number : TextInputType.text,
            enabled: active && c.phase == SshTunnelPhase.ready,
            autocorrect: false,
            enableSuggestions: false,
          ),
        ],
      ),
    );
    final busy =
        c.phase == SshTunnelPhase.loading ||
        c.phase == SshTunnelPhase.connecting ||
        c.phase == SshTunnelPhase.hostKey;
    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(largeTitle: Text(l.sshTunnelTitle)),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.profile.name),
                            Text(l.sshTunnelHint),
                            if (c.localEndpoint != null)
                              SelectableText(
                                c.localEndpoint!,
                                key: const ValueKey('tunnel-endpoint'),
                              ),
                            if (_formError != null || c.error != null)
                              Text(
                                l.sshTunnelFailed,
                                key: const ValueKey('tunnel-error'),
                              ),
                          ],
                        ),
                      ),
                      if (active && c.pendingPin != null)
                        SettingsSection(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: SelectableText(c.pendingPin!.fingerprint),
                            ),
                            action(
                              'tunnel-trust',
                              l.sshTrust,
                              () => unawaited(c.trustHost()),
                            ),
                            action('tunnel-cancel', l.commonCancel, c.cancel),
                          ],
                        )
                      else if (active && c.phase == SshTunnelPhase.active)
                        SettingsSection(
                          children: [
                            action('tunnel-stop', l.sshTunnelStop, c.cancel),
                          ],
                        )
                      else if (active && busy)
                        SettingsSection(
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(20),
                              child: CupertinoActivityIndicator(),
                            ),
                            action('tunnel-cancel', l.commonCancel, c.cancel),
                          ],
                        )
                      else if (active)
                        SettingsSection(
                          children: [
                            field('tunnel-name', l.sshTunnelName, _name),
                            field(
                              'tunnel-local-port',
                              l.sshTunnelLocalPort,
                              _local,
                              number: true,
                            ),
                            field(
                              'tunnel-target-host',
                              l.sshTunnelTargetHost,
                              _host,
                            ),
                            field(
                              'tunnel-target-port',
                              l.sshTunnelTargetPort,
                              _remote,
                              number: true,
                            ),
                            action(
                              'tunnel-save',
                              l.commonSave,
                              () => unawaited(_save()),
                            ),
                            action(
                              'tunnel-start',
                              l.sshTunnelStart,
                              () => unawaited(c.start()),
                              enabled: c.tunnel != null,
                            ),
                          ],
                        ),
                      if (active)
                        SettingsSection(
                          children: [
                            action('tunnel-back', l.commonBack, () {
                              c.cancel();
                              widget.onBack();
                            }),
                          ],
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
