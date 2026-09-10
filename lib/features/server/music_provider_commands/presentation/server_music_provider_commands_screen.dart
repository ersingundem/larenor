import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_music_provider_commands_controller.dart';

class ServerMusicProviderCommandTarget {
  const ServerMusicProviderCommandTarget({
    required this.installationId,
    required this.installationRevision,
    required this.providerSetupId,
    required this.providerRevision,
    required this.providerDomain,
  });

  final String installationId, providerSetupId, providerDomain;
  final int installationRevision, providerRevision;
}

/// PIN-gated, admin-only and route-scoped. No credential field is rendered.
/// A targetless entry explains the unavailable boundary without issuing a call.
class ServerMusicProviderCommandsScreen extends ConsumerStatefulWidget {
  const ServerMusicProviderCommandsScreen({super.key, this.target});

  final ServerMusicProviderCommandTarget? target;
  @override
  ConsumerState<ServerMusicProviderCommandsScreen> createState() =>
      _ServerMusicProviderCommandsScreenState();
}

class _ServerMusicProviderCommandsScreenState
    extends ConsumerState<ServerMusicProviderCommandsScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  ServerMusicProviderCommandsController? _commands;
  late final int _accountEpoch;
  bool _active = true, _pinReady = false;
  bool get _authorized =>
      _active &&
      _pinReady &&
      widget.target != null &&
      _account.isCurrent(_accountEpoch) &&
      _account.session?.user.canAdminister == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    if (widget.target case final target?) {
      _commands = ServerMusicProviderCommandsController(
        _account,
        installationId: target.installationId,
        installationRevision: target.installationRevision,
        providerSetupId: target.providerSetupId,
        providerRevision: target.providerRevision,
        providerDomain: target.providerDomain,
      )..addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool Function() _capture() {
    final generation = _account.generation;
    return () =>
        mounted &&
        _authorized &&
        _account.isCurrent(generation) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
  }

  void _retire() {
    if (!_active) return;
    _active = false;
    _commands?.invalidate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _retire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commands?.removeListener(_changed);
    _commands?.dispose();
    super.dispose();
  }

  String _provider(AppLocalizations l10n) =>
      switch (widget.target?.providerDomain) {
        'spotify' => 'Spotify',
        'apple_music' => 'Apple Music',
        'ytmusic' => 'YouTube Music',
        _ => l10n.serverMusicProviderCommandUnknown,
      };

  Widget _button(String key, String label, VoidCallback? action) =>
      CupertinoButton.filled(
        key: ValueKey(key),
        minimumSize: const Size(48, 48),
        onPressed: action,
        child: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _retire();
      }
    });
    final commands = _commands;
    final preview = commands?.preview;
    final result = commands?.command;
    final enabled = _authorized && commands?.busy == false;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.serverMusicProviderCommandTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                Semantics(
                  header: true,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(_provider(l10n), style: AppText.title1),
                  ),
                ),
                SettingsSection(
                  margin: const EdgeInsets.all(16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.serverMusicProviderCommandExplanation,
                            style: AppText.body,
                          ),
                          if (!_authorized) ...[
                            const SizedBox(height: 16),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _account.session?.user.canAdminister == true
                                    ? l10n.serverMusicProviderEffectUnavailable
                                    : l10n.serverFailurePermission,
                                style: AppText.headline,
                              ),
                            ),
                          ],
                          if (_authorized) ...[
                            const SizedBox(height: 16),
                            _button(
                              'provider-enable-preview',
                              l10n.serverMusicProviderEnable,
                              enabled
                                  ? () => unawaited(
                                      commands!.review(
                                        'enable',
                                        current: _capture(),
                                      ),
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            _button(
                              'provider-disable-preview',
                              l10n.serverMusicProviderDisable,
                              enabled
                                  ? () => unawaited(
                                      commands!.review(
                                        'disable',
                                        current: _capture(),
                                      ),
                                    )
                                  : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (preview != null)
                  SettingsSection(
                    margin: const EdgeInsets.all(16),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                l10n.serverMusicProviderEffectUnavailable,
                                style: AppText.headline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _button(
                              'provider-confirm',
                              l10n.serverMusicProviderConfirm,
                              enabled && result == null
                                  ? () => unawaited(
                                      commands!.confirm(current: _capture()),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                if (result != null)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        l10n.serverMusicProviderBlocked,
                        style: AppText.headline,
                      ),
                    ),
                  ),
                if (commands?.failure != null)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        l10n.serverFailureConnection,
                        style: AppText.body,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
