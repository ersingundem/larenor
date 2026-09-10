import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/remote_profiles.dart';
import 'ssh_engine.dart';
import 'ssh_security_store.dart';
import 'ssh_session_controller.dart';

final sshEngineFactoryProvider = Provider<SshEngine Function()>(
  (ref) => DartSshEngine.new,
);
final sshSecurityStoreProvider = Provider<SshSecurityStore>(
  (ref) => SshSecurityStore(),
);

/// Owned by the existing Settings/PIN page; entering this panel never connects.
class SshTerminalPanel extends ConsumerStatefulWidget {
  const SshTerminalPanel({
    super.key,
    required this.profile,
    required this.isCurrent,
    required this.onBack,
  });
  final RemoteProfile profile;
  final bool Function() isCurrent;
  final VoidCallback onBack;
  @override
  ConsumerState<SshTerminalPanel> createState() => _SshTerminalPanelState();
}

class _SshTerminalPanelState extends ConsumerState<SshTerminalPanel>
    with WidgetsBindingObserver {
  final _secret = TextEditingController(),
      _phrase = TextEditingController(),
      _line = TextEditingController();
  late SshSecurityStore _store;
  late SshEngine Function() _factory;
  late SshSessionController _session;
  ProviderContainer? _container;
  AppInteractionController? _interaction;
  bool _initialized = false,
      _retired = false,
      _busy = false,
      _hasCredential = false,
      _key = false,
      _forget = false,
      _resumed = true,
      _focused = true;
  String? _error;
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
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.of(context)?.isCurrent != true) {
        return false;
      }
      if (_initialized &&
          (!identical(_store, ref.read(sshSecurityStoreProvider)) ||
              !identical(_factory, ref.read(sshEngineFactoryProvider)))) {
        return false;
      }
      final state = ref.read(windowPolicySnapshotProvider);
      if (state.isLoading || state.hasError || !state.hasValue) return false;
      final w = state.value!;
      return !w.supported ||
          (w.isResumed && w.hasWindowFocus && !w.isPictureInPicture);
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
    final next = ProviderScope.containerOf(context, listen: false);
    if (_container != null && !identical(next, _container)) _retire();
    _container = next;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_ownerChanged);
      _interaction = interaction;
      interaction?.addListener(_ownerChanged);
    }
    if (!TickerMode.valuesOf(context).enabled) _retire();
  }

  @override
  void didUpdateWidget(covariant SshTerminalPanel old) {
    super.didUpdateWidget(old);
    if (old.profile.toJson().toString() != widget.profile.toJson().toString()) {
      _retire();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _retire();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent e) {
    if (mounted && e.viewId == View.of(context).viewId) {
      _focused = e.state == ViewFocusState.focused;
      if (!_focused) _retire();
    }
  }

  void _ownerChanged() {
    if (!_current()) _retire();
  }

  void _clear() {
    _secret.clear();
    _phrase.clear();
    _line.clear();
  }

  void _changed() {
    if (!mounted) return;
    void update() {
      if (!mounted) return;
      if (_retired ||
          _session.phase == SshSessionPhase.closed ||
          _session.phase == SshSessionPhase.failed) {
        _clear();
      }
      setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => update());
    } else {
      update();
    }
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    if (_initialized) _session.retire();
    _changed();
  }

  Future<void> _load() async {
    if (!_current()) return;
    setState(() => _busy = true);
    try {
      final credential = await _store.readCredential(
        widget.profile,
        isCurrent: _current,
      );
      if (_current()) setState(() => _hasCredential = credential != null);
    } catch (_) {
      if (_current()) setState(() => _error = 'storage_failed');
    } finally {
      if (mounted) {
        _busy = false;
        if (_current()) setState(() {});
      }
    }
  }

  Future<void> _save() async {
    if (!_current() || _busy) return;
    setState(() => _busy = true);
    final credential = SshCredential(
      _key ? SshCredentialKind.privateKey : SshCredentialKind.password,
      _secret.text,
      passphrase: _key ? _phrase.text : '',
    );
    try {
      await _store.saveCredential(
        widget.profile,
        credential,
        isCurrent: _current,
      );
      if (_current()) {
        _clear();
        setState(() {
          _hasCredential = true;
          _error = null;
        });
      }
    } catch (e) {
      if (_current()) {
        setState(() => _error = e is SshFailure ? e.code : 'storage_failed');
      }
    } finally {
      if (mounted) {
        _busy = false;
        if (_current()) setState(() {});
      }
    }
  }

  Future<void> _forgetCredential() async {
    if (!_current() || _busy || !_forget) return;
    setState(() => _busy = true);
    _forget = false;
    try {
      await _store.forgetCredential(widget.profile, isCurrent: _current);
      if (_current()) {
        _clear();
        setState(() {
          _hasCredential = false;
          _error = null;
        });
      }
    } catch (_) {
      if (_current()) setState(() => _error = 'storage_failed');
    } finally {
      if (mounted) {
        _busy = false;
        if (_current()) setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _retired = true;
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_ownerChanged);
    if (_initialized) {
      _session.removeListener(_changed);
      _session.dispose();
    }
    for (final f in [_secret, _phrase, _line]) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final store = ref.watch(sshSecurityStoreProvider),
        factory = ref.watch(sshEngineFactoryProvider);
    if (!_initialized) {
      _store = store;
      _factory = factory;
      _initialized = true;
      _session = SshSessionController(
        profile: widget.profile,
        store: store,
        engineFactory: factory,
        isCurrent: _current,
      )..addListener(_changed);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current()) _load();
      });
    }
    if (!identical(store, _store) || !identical(factory, _factory)) _retire();
    ref.listen(windowPolicySnapshotProvider, (_, next) {
      if (!_current()) _retire();
    });
    ref.watch(windowPolicySnapshotProvider);
    final active = _current();
    if (!active) _retire();
    final phase = _session.phase,
        busy =
            _busy ||
            phase == SshSessionPhase.connecting ||
            phase == SshSessionPhase.hostKey;
    Widget action(
      String key,
      String text,
      VoidCallback callback, {
      bool enabled = true,
    }) => SettingsActionTile(
      key: ValueKey(key),
      title: Text(text),
      onTap: active && enabled
          ? () {
              if (_current()) callback();
            }
          : null,
    );
    Widget field(
      String key,
      String label,
      TextEditingController controller, {
      bool secret = false,
      int lines = 1,
      int max = 4096,
      bool enabled = true,
    }) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 8),
          CupertinoTextField(
            key: ValueKey(key),
            controller: controller,
            placeholder: label,
            enabled: active && enabled,
            obscureText: secret,
            maxLines: lines,
            maxLength: max,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            padding: const EdgeInsets.all(14),
            textInputAction: TextInputAction.done,
          ),
        ],
      ),
    );
    final failure = _error ?? _session.error;
    String status() => switch (phase) {
      SshSessionPhase.idle => l.sshReady,
      SshSessionPhase.connecting => l.sshConnecting,
      SshSessionPhase.hostKey => l.sshVerifyHost,
      SshSessionPhase.connected => l.sshConnected,
      SshSessionPhase.closed => l.sshClosed,
      SshSessionPhase.failed => l.sshFailed,
    };
    String errorText() => switch (failure) {
      'host_changed' => l.sshHostChanged,
      'credential_missing' => l.sshCredentialMissing,
      'invalid_credential' => l.sshInvalidCredential,
      'profile_changed' => l.sshProfileChanged,
      'timed_out' => l.sshTimeout,
      'storage_failed' || 'invalid_record' => l.sshStorageFailed,
      'invalid_input' => l.sshInvalidInput,
      _ => l.sshFailed,
    };
    return AppPageScaffold(
      child: CustomScrollView(
        key: const ValueKey('ssh-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(largeTitle: Text(l.sshTitle)),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(header: true, child: Text(widget.profile.name)),
                      Text(
                        '${widget.profile.username}@${widget.profile.address}',
                      ),
                      const SizedBox(height: 12),
                      Text(l.sshHint),
                      const SizedBox(height: 12),
                      Text(
                        active ? status() : l.remoteAccessLocked,
                        key: const ValueKey('ssh-status'),
                      ),
                      if (failure != null)
                        Text(errorText(), key: const ValueKey('ssh-error')),
                    ],
                  ),
                ),
                if (active) ...[
                  if (_session.pendingPin case final pin?)
                    SettingsSection(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.sshTrustHint),
                              Text(pin.type),
                              SelectableText(
                                pin.fingerprint,
                                key: const ValueKey('ssh-fingerprint'),
                              ),
                            ],
                          ),
                        ),
                        action(
                          'ssh-trust',
                          l.sshTrust,
                          () => unawaited(_session.trustHost()),
                        ),
                        action('ssh-cancel', l.commonCancel, _session.cancel),
                      ],
                    )
                  else if (phase == SshSessionPhase.connected) ...[
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _session.transcript.isEmpty
                            ? l.sshWaitingOutput
                            : _session.transcript,
                        key: const ValueKey('ssh-output'),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    SettingsSection(
                      children: [
                        field('ssh-line', l.sshLine, _line),
                        action('ssh-send', l.sshSend, () {
                          final line = _line.text;
                          _line.clear();
                          unawaited(_session.sendLine(line));
                        }),
                        action(
                          'ssh-disconnect',
                          l.sshDisconnect,
                          _session.cancel,
                        ),
                      ],
                    ),
                  ] else if (busy)
                    SettingsSection(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: CupertinoActivityIndicator(),
                        ),
                        action('ssh-cancel', l.commonCancel, _session.cancel),
                      ],
                    )
                  else
                    SettingsSection(
                      children: [
                        if (_hasCredential) ...[
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(l.sshCredentialSaved),
                          ),
                          action(
                            'ssh-connect',
                            l.sshConnect,
                            () => unawaited(_session.connect()),
                          ),
                          if (_forget) ...[
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(l.sshForgetConfirm),
                            ),
                            action(
                              'ssh-forget-confirm',
                              l.commonDelete,
                              () => unawaited(_forgetCredential()),
                            ),
                            action(
                              'ssh-forget-cancel',
                              l.commonCancel,
                              () => setState(() => _forget = false),
                            ),
                          ] else
                            action(
                              'ssh-forget',
                              l.sshForget,
                              () => setState(() => _forget = true),
                            ),
                        ],
                        action('ssh-password-mode', l.sshPassword, () {
                          _clear();
                          setState(() => _key = false);
                        }),
                        action('ssh-key-mode', l.sshPrivateKey, () {
                          _clear();
                          setState(() => _key = true);
                        }),
                        field(
                          _key ? 'ssh-private-key' : 'ssh-password',
                          _key ? l.sshPrivateKey : l.sshPassword,
                          _secret,
                          secret: !_key,
                          lines: _key ? 4 : 1,
                          max: _key ? 32768 : 4096,
                        ),
                        if (_key)
                          field(
                            'ssh-passphrase',
                            l.sshPassphrase,
                            _phrase,
                            secret: true,
                            max: 1024,
                          ),
                        action(
                          'ssh-save-credential',
                          l.sshSaveCredential,
                          () => unawaited(_save()),
                        ),
                        action(
                          'ssh-reload-credential',
                          l.commonRefresh,
                          () => unawaited(_load()),
                        ),
                      ],
                    ),
                  SettingsSection(
                    children: [
                      action('ssh-back', l.commonBack, () {
                        _session.cancel();
                        _clear();
                        widget.onBack();
                      }),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
