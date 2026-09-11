import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/remote_profiles.dart';
import '../ssh/sftp_browser_panel.dart';
import '../ssh/ssh_terminal_panel.dart';
import '../ssh/ssh_tunnel_panel.dart';
import '../rdp/rdp_session_panel.dart';
import '../vnc/vnc_session_panel.dart';

final remoteProfilesStoreProvider = Provider<RemoteProfilesStore>(
  (ref) => RemoteProfilesStore(),
);

class RemoteProfilesScreen extends ConsumerStatefulWidget {
  const RemoteProfilesScreen({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<RemoteProfilesScreen> createState() =>
      _RemoteProfilesScreenState();
}

class _RemoteProfilesScreenState extends ConsumerState<RemoteProfilesScreen>
    with WidgetsBindingObserver {
  final _name = TextEditingController(),
      _host = TextEditingController(),
      _port = TextEditingController(),
      _user = TextEditingController();
  AppInteractionController? _interaction;
  ProviderContainer? _container;
  RemoteProfilesStore? _store;
  RemoteProfilesSnapshot? _snapshot;
  RemoteProfile? _selected;
  RemoteProtocol _protocol = RemoteProtocol.ssh;
  int _generation = 0, _interactionEpoch = 0;
  bool _resumed = true,
      _nativeFocused = true,
      _terminal = false,
      _sftp = false,
      _tunnel = false;
  bool _rdp = false;
  bool _vnc = false;
  bool Function()? _terminalCurrent;
  bool Function()? _sftpCurrent;
  bool Function()? _tunnelCurrent;
  bool Function()? _rdpCurrent;
  bool Function()? _vncCurrent;
  bool _started = false,
      _busy = false,
      _editing = false,
      _deleting = false,
      _retired = false;
  String? _error, _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ProviderScope.containerOf(context, listen: false);
    if (_container != null && !identical(next, _container)) {
      _retired = true;
      _invalidate();
    }
    _container = next;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      if (_interaction != null) _invalidate();
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interactionEpoch = interaction?.epoch ?? 0;
      interaction?.addListener(_interactionChanged);
    }
    if (!TickerMode.valuesOf(context).enabled) _invalidate();
  }

  void _interactionChanged() {
    if (_interaction?.epoch != _interactionEpoch) {
      _interactionEpoch = _interaction?.epoch ?? 0;
      _invalidate();
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _invalidate();
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (mounted && event.viewId == View.of(context).viewId) {
      _nativeFocused = event.state == ViewFocusState.focused;
      if (!_nativeFocused) _invalidate();
      setState(() {});
    }
  }

  void _invalidate() {
    _terminal = false;
    _sftp = false;
    _tunnel = false;
    _terminalCurrent = null;
    _sftpCurrent = null;
    _tunnelCurrent = null;
    _generation++;
    _snapshot = null;
    _selected = null;
    _busy = false;
    _editing = false;
    _deleting = false;
    _started = false;
    _error = null;
    _notice = null;
    for (final field in [_name, _host, _port, _user]) {
      field.clear();
    }
  }

  bool _current(int generation) {
    try {
      if (!mounted ||
          !_resumed ||
          !_nativeFocused ||
          _retired ||
          generation != _generation ||
          !widget.gateCurrent() ||
          _interaction?.active == false ||
          (_interaction?.epoch ?? 0) != _interactionEpoch ||
          ModalRoute.of(context)?.isCurrent != true ||
          !TickerMode.valuesOf(context).enabled ||
          !identical(
            _container,
            ProviderScope.containerOf(context, listen: false),
          ) ||
          !identical(_store, ref.read(remoteProfilesStoreProvider))) {
        return false;
      }
      final state = ref.read(windowPolicySnapshotProvider);
      if (state.isLoading || state.hasError || !state.hasValue) return false;
      final window = state.value!;
      return !window.supported ||
          (window.isResumed &&
              window.hasWindowFocus &&
              !window.isPictureInPicture);
    } catch (_) {
      return false;
    }
  }

  bool Function() _action() {
    final generation = _generation;
    var retired = false;
    return () {
      if (retired) return false;
      return !(retired = !_current(generation));
    };
  }

  void _fail(Object error) {
    _generation++;
    _busy = false;
    _snapshot = null;
    _selected = null;
    _editing = false;
    _deleting = false;
    for (final field in [_name, _host, _port, _user]) {
      field.clear();
    }
    _error = error is RemoteProfilesFailure ? error.code : 'read_failed';
  }

  Future<void> _load(bool Function() current) async {
    if (!current() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final value = await _store!.read(isCurrent: current);
      if (current()) {
        setState(() {
          _snapshot = value;
          _busy = false;
        });
        _generation++;
      }
    } catch (error) {
      if (current()) setState(() => _fail(error));
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  void _edit(RemoteProfile? profile) {
    _generation++;
    _selected = profile;
    _editing = true;
    _deleting = false;
    _error = null;
    _notice = null;
    _protocol = profile?.protocol ?? RemoteProtocol.ssh;
    _name.text = profile?.name ?? '';
    _host.text = profile?.host ?? '';
    _port.text = '${profile?.port ?? remoteDefaultPort(_protocol)}';
    _user.text = profile?.username ?? '';
    setState(() {});
  }

  Future<void> _save(bool Function() current) async {
    if (!current() || _busy || _snapshot == null) return;
    RemoteProfile profile;
    try {
      final port = int.tryParse(_port.text);
      if (port == null || port < 1 || port > 65535) {
        throw const RemoteProfilesFailure('invalid_port');
      }
      profile = RemoteProfile(
        id:
            _selected?.id ??
            List.generate(
              16,
              (_) => Random.secure()
                  .nextInt(256)
                  .toRadixString(16)
                  .padLeft(2, '0'),
            ).join(),
        name: _name.text.trim(),
        protocol: _protocol,
        host: normalizeRemoteHost(_host.text),
        port: port,
        username: _user.text.trim(),
      );
      profile.toJson();
    } catch (error) {
      if (current()) {
        setState(
          () => _error = error is RemoteProfilesFailure
              ? error.code
              : 'invalid_record',
        );
      }
      return;
    }
    final rows = [..._snapshot!.profiles];
    final index = rows.indexWhere((p) => p.id == profile.id);
    if (index < 0) {
      rows.add(profile);
    } else {
      rows[index] = profile;
    }
    await _replace(rows, current);
  }

  Future<void> _replace(
    List<RemoteProfile> rows,
    bool Function() current,
  ) async {
    if (!current() || _busy || _snapshot == null) return;
    final before = _snapshot!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _store!.replace(before, rows, isCurrent: current);
      if (current()) {
        setState(() {
          _busy = false;
          _snapshot = result;
          _selected = null;
          _editing = false;
          _deleting = false;
          _notice = 'saved';
          for (final field in [_name, _host, _port, _user]) {
            field.clear();
          }
        });
        _generation++;
      }
    } catch (error) {
      if (current()) setState(() => _fail(error));
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _copy(RemoteProfile profile, bool Function() current) async {
    if (!current() || _busy) return;
    try {
      await Clipboard.setData(ClipboardData(text: profile.address));
      if (current()) setState(() => _notice = 'copied');
    } catch (_) {
      if (current()) setState(() => _error = 'copy_failed');
    }
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    for (final field in [_name, _host, _port, _user]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final store = ref.watch(remoteProfilesStoreProvider);
    if (_store != null && !identical(store, _store)) {
      _retired = true;
      _invalidate();
    }
    _store = store;
    ref.listen(windowPolicySnapshotProvider, (previous, next) {
      final w = next.value;
      if (next.isLoading ||
          next.hasError ||
          w == null ||
          (w.supported &&
              (!w.isResumed || !w.hasWindowFocus || w.isPictureInPicture))) {
        _invalidate();
        if (mounted) setState(() {});
      }
    });
    ref.watch(windowPolicySnapshotProvider);
    final current = _action(), active = current();
    if (active && !_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current()) _load(current);
      });
    }
    Widget action(
      String key,
      String title,
      VoidCallback? callback, {
      String? subtitle,
    }) => SettingsActionTile(
      key: ValueKey(key),
      title: Text(title),
      additionalInfo: subtitle == null ? null : Text(subtitle),
      onTap: !active || _busy || callback == null
          ? null
          : () {
              if (current()) callback();
            },
    );
    Widget field(
      String key,
      String label,
      TextEditingController controller, {
      TextInputType? type,
      bool last = false,
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
            enabled: active && !_busy,
            placeholder: label,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: type,
            textInputAction: last ? TextInputAction.done : TextInputAction.next,
            maxLength: key == 'remote-name'
                ? 80
                : key == 'remote-user'
                ? 128
                : key == 'remote-port'
                ? 5
                : 253,
            padding: const EdgeInsets.all(14),
            onSubmitted: last
                ? (_) {
                    if (current()) _save(current);
                  }
                : null,
          ),
        ],
      ),
    );
    String errorText() => switch (_error) {
      'invalid_host' => l.remoteAccessInvalidHost,
      'invalid_port' => l.remoteAccessInvalidPort,
      'invalid_record' => l.remoteAccessInvalidRecord,
      'conflict' => l.remoteAccessConflict,
      'write_unconfirmed' => l.remoteAccessWriteUnconfirmed,
      'limit' => l.remoteAccessLimit,
      'copy_failed' => l.remoteAccessCopyFailed,
      _ => l.remoteAccessReadFailed,
    };
    if (_terminal && _selected != null && active) {
      return SshTerminalPanel(
        key: ValueKey("ssh-${_selected!.id}"),
        profile: _selected!,
        availableProfiles: _snapshot?.profiles ?? const [],
        isCurrent: _terminalCurrent!,
        onBack: () {
          _generation++;
          setState(() => _terminal = false);
        },
      );
    }
    if (_sftp && _selected != null && active) {
      return SftpBrowserPanel(
        key: ValueKey("sftp-${_selected!.id}"),
        profile: _selected!,
        isCurrent: _sftpCurrent!,
        onBack: () {
          _generation++;
          setState(() => _sftp = false);
        },
      );
    }
    if (_tunnel && _selected != null && active) {
      return SshTunnelPanel(
        key: ValueKey("tunnel-${_selected!.id}"),
        profile: _selected!,
        isCurrent: _tunnelCurrent!,
        onBack: () {
          _generation++;
          setState(() => _tunnel = false);
        },
      );
    }
    if (_rdp && _selected != null && active) {
      return RdpSessionPanel(
        key: ValueKey('rdp-${_selected!.id}'),
        profile: _selected!,
        isCurrent: _rdpCurrent!,
        onBack: () {
          _generation++;
          setState(() => _rdp = false);
        },
      );
    }
    if (_vnc && _selected != null && active) {
      return VncSessionPanel(
        key: ValueKey('vnc-${_selected!.id}'),
        profile: _selected!,
        isCurrent: _vncCurrent!,
        onBack: () {
          _generation++;
          setState(() => _vnc = false);
        },
      );
    }
    return AppPageScaffold(
      child: CustomScrollView(
        key: const ValueKey('remote-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(largeTitle: Text(l.remoteAccessTitle)),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(l.remoteAccessPrivacy),
                ),
                if (!active)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(l.remoteAccessLocked),
                  )
                else ...[
                  if (_busy) const Center(child: CupertinoActivityIndicator()),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        errorText(),
                        key: const ValueKey('remote-error'),
                      ),
                    ),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _notice == 'copied'
                            ? l.remoteAccessCopied
                            : l.remoteAccessSaved,
                        key: const ValueKey('remote-notice'),
                      ),
                    ),
                  if (_editing)
                    SettingsSection(
                      children: [
                        field('remote-name', l.remoteAccessName, _name),
                        for (final protocol in RemoteProtocol.values)
                          action(
                            'remote-protocol-${protocol.name}',
                            '${protocol.name.toUpperCase()}${protocol == _protocol ? ' ✓' : ''}',
                            () {
                              final previousDefault = remoteDefaultPort(
                                _protocol,
                              );
                              _protocol = protocol;
                              if (_port.text == '$previousDefault') {
                                _port.text = '${remoteDefaultPort(protocol)}';
                              }
                              setState(() {});
                            },
                          ),
                        field(
                          'remote-host',
                          l.remoteAccessHost,
                          _host,
                          type: TextInputType.url,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(l.remoteAccessHostHint),
                        ),
                        field(
                          'remote-port',
                          l.remoteAccessPort,
                          _port,
                          type: TextInputType.number,
                        ),
                        field(
                          'remote-user',
                          l.remoteAccessUsername,
                          _user,
                          last: true,
                        ),
                        action(
                          'remote-save',
                          l.commonSave,
                          () => _save(current),
                        ),
                        action('remote-cancel', l.commonCancel, () {
                          _generation++;
                          setState(() {
                            _editing = false;
                            _selected = null;
                            _error = null;
                            for (final f in [_name, _host, _port, _user]) {
                              f.clear();
                            }
                          });
                        }),
                      ],
                    )
                  else if (_selected case final selected?)
                    SettingsSection(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Semantics(
                            header: true,
                            child: Text(selected.name),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            '${selected.protocol.name.toUpperCase()} · ${selected.address}${selected.username.isEmpty ? '' : '\n${selected.username}'}',
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            selected.protocol == RemoteProtocol.ssh
                                ? l.sshHint
                                : selected.protocol == RemoteProtocol.rdp
                                ? l.rdpProfileHint
                                : selected.protocol == RemoteProtocol.vnc
                                ? l.vncProfileHint
                                : l.remoteAccessEngineHint,
                          ),
                        ),
                        if (_deleting) ...[
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              l.remoteAccessDeleteConfirm(selected.name),
                            ),
                          ),
                          action(
                            'remote-delete-confirm',
                            l.commonDelete,
                            () => _replace(
                              _snapshot!.profiles
                                  .where((p) => p.id != selected.id)
                                  .toList(),
                              current,
                            ),
                          ),
                          action('remote-delete-cancel', l.commonCancel, () {
                            _generation++;
                            setState(() => _deleting = false);
                          }),
                        ] else ...[
                          if (selected.protocol == RemoteProtocol.ssh &&
                              selected.username.isNotEmpty) ...[
                            action('remote-ssh-open', l.sshTitle, () {
                              _generation++;
                              _terminalCurrent = _action();
                              setState(() => _terminal = true);
                            }),
                            action('remote-sftp-open', l.sftpTitle, () {
                              _generation++;
                              _sftpCurrent = _action();
                              setState(() => _sftp = true);
                            }),
                            action('remote-tunnel-open', l.sshTunnelTitle, () {
                              _generation++;
                              _tunnelCurrent = _action();
                              setState(() => _tunnel = true);
                            }),
                          ],
                          if (selected.protocol == RemoteProtocol.rdp &&
                              selected.username.isNotEmpty)
                            action('remote-rdp-open', l.rdpTitle, () {
                              _generation++;
                              _rdpCurrent = _action();
                              setState(() => _rdp = true);
                            }),
                          if (selected.protocol == RemoteProtocol.vnc)
                            action('remote-vnc-open', l.vncTitle, () {
                              _generation++;
                              _vncCurrent = _action();
                              setState(() => _vnc = true);
                            }),
                          action(
                            'remote-copy',
                            l.remoteAccessCopy,
                            () => _copy(selected, current),
                          ),
                          action(
                            'remote-edit',
                            l.commonEdit,
                            () => _edit(selected),
                          ),
                          action('remote-delete', l.commonDelete, () {
                            _generation++;
                            setState(() => _deleting = true);
                          }),
                          action('remote-list', l.commonBack, () {
                            _generation++;
                            setState(() => _selected = null);
                          }),
                        ],
                      ],
                    )
                  else ...[
                    if (_snapshot != null && _snapshot!.profiles.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(l.remoteAccessEmpty),
                      ),
                    if (_snapshot?.profiles.isNotEmpty == true)
                      SettingsSection(
                        children: [
                          for (final profile in _snapshot!.profiles)
                            action(
                              'remote-profile-${profile.id}',
                              profile.name,
                              () {
                                _generation++;
                                setState(() {
                                  _selected = profile;
                                  _notice = null;
                                });
                              },
                              subtitle:
                                  '${profile.protocol.name.toUpperCase()} · ${profile.address}',
                            ),
                        ],
                      ),
                    SettingsSection(
                      children: [
                        action(
                          'remote-add',
                          l.remoteAccessAdd,
                          _snapshot == null ? null : () => _edit(null),
                        ),
                        action(
                          'remote-refresh',
                          l.commonRefresh,
                          () => _load(current),
                        ),
                      ],
                    ),
                  ],
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
