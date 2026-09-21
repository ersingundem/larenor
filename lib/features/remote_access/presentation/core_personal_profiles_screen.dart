import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/connection_evidence_status.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../server/providers/server_providers.dart';
import '../core/core_personal_profiles.dart';
import '../core/core_personal_profiles_controller.dart';
import '../data/remote_profiles.dart';

class CorePersonalProfilesScreen extends ConsumerStatefulWidget {
  const CorePersonalProfilesScreen({
    super.key,
    required this.isCurrent,
    required this.onBack,
  });

  final bool Function() isCurrent;
  final VoidCallback onBack;

  @override
  ConsumerState<CorePersonalProfilesScreen> createState() =>
      _CorePersonalProfilesScreenState();
}

class _CorePersonalProfilesScreenState
    extends ConsumerState<CorePersonalProfilesScreen> {
  final _name = TextEditingController(),
      _host = TextEditingController(),
      _port = TextEditingController(),
      _user = TextEditingController();
  CorePersonalProfilesController? _controller;
  CorePersonalProfile? _editing;
  String? _conflictedId;
  RemoteProtocol _protocol = RemoteProtocol.ssh;
  bool _creating = false, _deleteConfirm = false;

  bool _current() {
    try {
      return mounted && widget.isCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = ref.read(serverAccountControllerProvider);
    if (_controller != null && !identical(_controller!.account, account)) {
      _controller!.dispose();
      _controller = null;
    }
    _controller ??= CorePersonalProfilesController(
      account: account,
      windowCurrent: _current,
    )..addListener(_changed);
    _controller!.setVisible(true);
  }

  void _changed() {
    if (!mounted) return;
    final controller = _controller;
    if (controller?.mutationOutcome == CoreProfileMutationOutcome.conflict) {
      _conflictedId = _editing?.id;
    } else if (_conflictedId != null &&
        controller?.evidence.isFreshVerified == true) {
      for (final item in controller!.profiles) {
        if (item.id == _conflictedId) {
          // Keep the user's draft, but bind its next explicit save/delete to
          // the freshly verified record revision.
          _editing = item;
          break;
        }
      }
      _conflictedId = null;
    }
    if (controller?.mutationOutcome
        case CoreProfileMutationOutcome.saved ||
            CoreProfileMutationOutcome.deleted) {
      _closeEditor();
    }
    setState(() {});
  }

  void _edit(CorePersonalProfile? profile) {
    _editing = profile;
    _creating = profile == null;
    _deleteConfirm = false;
    _conflictedId = null;
    _protocol = profile?.profile.protocol ?? RemoteProtocol.ssh;
    _name.text = profile?.profile.name ?? '';
    _host.text = profile?.profile.host ?? '';
    _port.text = '${profile?.profile.port ?? remoteDefaultPort(_protocol)}';
    _user.text = profile?.profile.username ?? '';
    setState(() {});
  }

  void _closeEditor() {
    _editing = null;
    _creating = false;
    _deleteConfirm = false;
    _conflictedId = null;
    for (final field in [_name, _host, _port, _user]) {
      field.clear();
    }
  }

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || !_current()) return;
    try {
      final port = int.tryParse(_port.text);
      if (port == null || port < 1 || port > 65535) return;
      final desired = RemoteProfile(
        id:
            _editing?.id ??
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
      desired.toJson();
      final target = _editing;
      if (target == null) {
        await controller.create(desired, ownerCurrent: _current);
      } else {
        await controller.update(target, desired, ownerCurrent: _current);
      }
    } catch (_) {
      // Local validation remains local and carries no entered metadata.
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.setVisible(false);
    _controller?.dispose();
    for (final field in [_name, _host, _port, _user]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(serverAccountControllerProvider);
    final l = AppLocalizations.of(context);
    final controller = _controller!;
    Widget action(String key, String title, VoidCallback? onTap) =>
        SettingsActionTile(
          key: ValueKey(key),
          title: Text(title),
          onTap: controller.busy || !_current() ? null : onTap,
        );
    Widget field(
      String key,
      String label,
      TextEditingController value, {
      TextInputType? keyboard,
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
            controller: value,
            enabled: controller.canMutate && !controller.busy,
            keyboardType: keyboard,
            autocorrect: false,
            enableSuggestions: false,
            padding: const EdgeInsets.all(14),
            textInputAction: last ? TextInputAction.done : TextInputAction.next,
            onSubmitted: last ? (_) => _save() : null,
          ),
        ],
      ),
    );

    final conflict =
        controller.mutationOutcome == CoreProfileMutationOutcome.conflict;
    return AppPageScaffold(
      child: CustomScrollView(
        key: const ValueKey('core-profiles-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(
            automaticallyImplyLeading: false,
            largeTitle: Text(l.remoteAccessCoreProfiles),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                SettingsSection(
                  children: [
                    action('core-profiles-back', l.commonBack, widget.onBack),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Semantics(
                    key: const ValueKey('core-profile-source-status'),
                    container: true,
                    liveRegion: true,
                    label:
                        '${l.remoteAccessCoreManaged}. ${l.remoteAccessCoreScope}',
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.remoteAccessCoreManaged,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .navTitleTextStyle,
                          ),
                          const SizedBox(height: 6),
                          Text(l.remoteAccessCoreScope),
                          const SizedBox(height: 12),
                          ConnectionEvidenceStatus(
                            evidence: controller.evidence,
                            compact: true,
                            showTimestamp: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (controller.busy)
                  const Center(child: CupertinoActivityIndicator()),
                if (conflict)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(l.remoteAccessCoreConflict),
                    ),
                  ),
                if (controller.failure != null && !conflict)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(l.remoteAccessCoreUnavailable),
                    ),
                  ),
                SettingsSection(
                  children: [
                    action(
                      'core-profiles-refresh',
                      conflict ? l.remoteAccessCoreResolve : l.commonRefresh,
                      controller.canRefresh ? controller.refresh : null,
                    ),
                    action(
                      'core-profiles-add',
                      l.remoteAccessCoreAdd,
                      controller.canMutate ? () => _edit(null) : null,
                    ),
                  ],
                ),
                if (_creating || _editing != null)
                  SettingsSection(
                    children: [
                      field('core-profile-name', l.remoteAccessName, _name),
                      for (final protocol in RemoteProtocol.values)
                        action(
                          'core-profile-protocol-${protocol.name}',
                          '${protocol.name.toUpperCase()}${_protocol == protocol ? ' ✓' : ''}',
                          () {
                            final old = remoteDefaultPort(_protocol);
                            _protocol = protocol;
                            if (_port.text == '$old') {
                              _port.text = '${remoteDefaultPort(protocol)}';
                            }
                            setState(() {});
                          },
                        ),
                      field('core-profile-host', l.remoteAccessHost, _host),
                      field(
                        'core-profile-port',
                        l.remoteAccessPort,
                        _port,
                        keyboard: TextInputType.number,
                      ),
                      field(
                        'core-profile-user',
                        l.remoteAccessUsername,
                        _user,
                        last: true,
                      ),
                      action('core-profile-save', l.commonSave, _save),
                      action('core-profile-cancel', l.commonCancel, () {
                        _closeEditor();
                        setState(() {});
                      }),
                    ],
                  )
                else if (controller.loaded || controller.profiles.isNotEmpty)
                  SettingsSection(
                    children: [
                      if (controller.loaded && controller.profiles.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l.remoteAccessCoreEmpty),
                        ),
                      for (final item in controller.profiles)
                        SettingsActionTile(
                          key: ValueKey('core-profile-${item.id}'),
                          title: Text(item.profile.name),
                          additionalInfo: Text(
                            '${item.profile.protocol.name.toUpperCase()} · ${item.profile.address}',
                          ),
                          onTap: controller.canMutate
                              ? () => _edit(item)
                              : null,
                        ),
                    ],
                  ),
                if (_editing != null && !_creating)
                  SettingsSection(
                    children: [
                      if (_deleteConfirm) ...[
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            l.remoteAccessDeleteConfirm(_editing!.profile.name),
                          ),
                        ),
                        action(
                          'core-profile-delete-confirm',
                          l.commonDelete,
                          () {
                            controller.delete(
                              _editing!,
                              ownerCurrent: _current,
                            );
                          },
                        ),
                      ] else
                        action('core-profile-delete', l.commonDelete, () {
                          setState(() => _deleteConfirm = true);
                        }),
                    ],
                  ),
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
