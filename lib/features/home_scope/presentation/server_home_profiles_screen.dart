import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/core_backups/presentation/server_core_backups_screen.dart';
import '../../server/domain/server_home_registry.dart';
import '../../server/providers/server_providers.dart';
import '../../settings/providers/settings_providers.dart';

class ServerHomeProfilesScreen extends ConsumerStatefulWidget {
  const ServerHomeProfilesScreen({super.key});

  @override
  ConsumerState<ServerHomeProfilesScreen> createState() =>
      _ServerHomeProfilesScreenState();
}

class _ServerHomeProfilesScreenState
    extends MediaSessionState<ServerHomeProfilesScreen> {
  late final ServerAccountController _account;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _pinReady = false, _expired = false;
  String? _notice;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
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
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
  }

  @override
  void clearPendingInteraction() => _expire();

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  Future<void> _add() async {
    if (!_active || _account.working) return;
    final current = _capture();
    await _account.beginAddProfile();
    if (!mounted || !current()) return;
    Navigator.of(context).pop();
  }

  Future<void> _choose(ServerHomeProfile profile) async {
    if (!_active || _account.working) return;
    final current = _capture();
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final action = await showCupertinoModalPopup<_ProfileAction>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(profile.label),
        message: Text(
          '${profile.session.user.username} · ${profile.session.endpoint.uri.host}',
        ),
        actions: [
          if (_account.activeProfileId != profile.profileId)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, _ProfileAction.activate),
              child: Text(l10n.serverHomesSwitch),
            ),
          if (_account.activeProfileId == profile.profileId &&
              profile.session.user.canAdminister)
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.pop(context, _ProfileAction.recoveryTarget),
              child: Text(l10n.serverHomesRecoveryTarget),
            ),
          if (_account.activeProfileId == profile.profileId &&
              _account.profiles.length > 1)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, _ProfileAction.handoff),
              child: Text(l10n.serverHomesHandoff),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, _ProfileAction.rename),
            child: Text(l10n.serverHomesRename),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, _ProfileAction.remove),
            child: Text(l10n.serverHomesRemove),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (!current() || action == null) return;
    switch (action) {
      case _ProfileAction.activate:
        await _account.activateProfile(profile.profileId);
      case _ProfileAction.rename:
        await _rename(profile);
      case _ProfileAction.remove:
        await _remove(profile);
      case _ProfileAction.recoveryTarget:
        await navigator.push<void>(
          CupertinoPageRoute(builder: (_) => const ServerCoreBackupsScreen()),
        );
      case _ProfileAction.handoff:
        await _verifyHandoff(profile);
    }
  }

  Future<void> _verifyHandoff(ServerHomeProfile source) async {
    final current = _capture();
    final l10n = AppLocalizations.of(context);
    final targets = _account.profiles
        .where((item) => item.profileId != source.profileId)
        .toList(growable: false);
    final target = await showCupertinoModalPopup<ServerHomeProfile>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.serverHomesHandoffTitle),
        message: Text(l10n.serverHomesHandoffHint),
        actions: [
          for (final item in targets)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (!current() || target == null) return;
    try {
      await _account.verifyCrossHomeAuthorization(target.profileId);
      if (current()) {
        setState(
          () => _notice = l10n.serverHomesHandoffVerified(
            source.label,
            target.label,
          ),
        );
      }
    } catch (_) {
      if (current()) setState(() => _notice = null);
    }
  }

  Future<void> _rename(ServerHomeProfile profile) async {
    final current = _capture();
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: profile.label);
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.serverHomesRenameTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            key: const ValueKey('server-home-profile-label'),
            controller: controller,
            maxLength: 80,
            autofocus: true,
            placeholder: l10n.serverHomesName,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!current() || value == null) return;
    await _account.renameProfile(profile.profileId, value.trim());
  }

  Future<void> _remove(ServerHomeProfile profile) async {
    final current = _capture();
    final l10n = AppLocalizations.of(context);
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.serverHomesRemoveTitle),
        content: Text(l10n.serverHomesRemoveHint(profile.label)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (!current() || accepted != true) return;
    await _account.removeProfile(profile.profileId);
  }

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          previous?.hasValue == true && previous?.value != next.value) {
        _expire();
      }
    });
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.serverHomesTitle),
        trailing: CupertinoButton(
          key: const ValueKey('server-home-add'),
          padding: EdgeInsets.zero,
          onPressed:
              _active &&
                  !_account.working &&
                  _account.profiles.length < maxServerHomeProfiles
              ? _add
              : null,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _account,
          builder: (context, _) {
            if (!_active) {
              return Center(child: Text(l10n.serverOpenFromSettings));
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    SettingsSection(
                      header: Text(l10n.serverHomesTitle),
                      footer: Text(l10n.serverHomesIntro),
                      children: [
                        for (final profile in _account.profiles)
                          SettingsActionTile(
                            buttonKey: ValueKey(
                              'server-home-${profile.profileId}',
                            ),
                            leading: Icon(
                              _account.activeProfileId == profile.profileId
                                  ? CupertinoIcons.house_fill
                                  : CupertinoIcons.house,
                            ),
                            title: Text(profile.label),
                            additionalInfo: Text(
                              _account.activeProfileId == profile.profileId
                                  ? l10n.serverHomesActive
                                  : '${profile.session.user.username} · ${profile.session.endpoint.uri.host}',
                            ),
                            selected:
                                _account.activeProfileId == profile.profileId,
                            onTap: _account.working
                                ? null
                                : () => _choose(profile),
                          ),
                      ],
                    ),
                    if (_account.working) const CupertinoActivityIndicator(),
                    if (_notice != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_notice!),
                      ),
                    if (_account.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n.serverHomesOperationFailed),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _ProfileAction { activate, recoveryTarget, handoff, rename, remove }
