import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/providers/server_providers.dart';
import '../data/client_release_repository.dart';
import '../data/client_update_controller.dart';
import '../domain/client_update_models.dart';
import '../providers/client_update_providers.dart';

typedef ClientReleaseFactory = ClientReleaseRepository Function(
  ClientUpdateSource,
);
final clientReleaseFactoryProvider = Provider<ClientReleaseFactory>(
  (ref) =>
      (source) => ClientReleaseRepository(
        baseUrl: source.baseUrl,
        accessToken: source.accessToken,
        isCurrent: source.isCurrent,
      ),
);

class ClientUpdatesScreen extends ConsumerStatefulWidget {
  const ClientUpdatesScreen({super.key, this.onExit});
  final VoidCallback? onExit;
  @override
  ConsumerState<ClientUpdatesScreen> createState() =>
      _ClientUpdatesScreenState();
}

class _ClientUpdatesScreenState extends MediaSessionState<ClientUpdatesScreen> {
  late final ServerAccountController _account;
  ClientUpdateController? _update;
  ClientReleaseRepository? _repository;
  ServerSession? _boundSession;
  ClientRelease? _available;
  ClientUpdateFailure? _error;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true;
  bool _checking = false;
  bool _checked = false;
  bool _disposed = false;
  int _operation = 0;

  bool get _active =>
      sessionCurrent(sessionGeneration) &&
      _visible &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  bool get _signedIn =>
      _account.session != null && !_account.session!.user.mustChangePassword;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active && _signedIn) _check();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.getValuesNotifier(context);
    if (!identical(next, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = next;
      _visible = next.value.enabled;
      next.addListener(_visibilityChanged);
    }
    ModalRoute.isCurrentOf(context);
    if (!_active) clearPendingInteraction();
  }

  void _visibilityChanged() {
    if (!mounted) return;
    _visible = _ticker?.value.enabled ?? true;
    if (!_active) clearPendingInteraction();
    setState(() {});
  }

  void _accountChanged() {
    if (!mounted || _disposed) return;
    if (_boundSession != null && !identical(_boundSession, _account.session)) {
      _operation++;
      _retire();
      _available = null;
      _checking = false;
      _checked = false;
      _error = ClientUpdateFailure.expired;
    }
    setState(() {});
  }

  void _retire() {
    _repository?.close();
    _repository = null;
    _update?.removeListener(_updated);
    _update?.dispose();
    _update = null;
    _boundSession = null;
  }

  @override
  void clearPendingInteraction() {
    _operation++;
    _repository?.close();
    _repository = null;
    _checking = false;
    _update?.setVisible(false);
  }

  void _updated() {
    if (mounted && !_disposed) setState(() {});
  }

  Future<void> _check() async {
    if (!_active || !_signedIn || _checking || _update?.busy == true) return;
    final operation = ++_operation;
    final epoch = sessionGeneration;
    _retire();
    setState(() {
      _checking = true;
      _error = null;
      _available = null;
      _checked = false;
    });
    try {
      final session = await _account.ensureSession();
      if (!_current(operation, epoch)) return;
      final generation = _account.generation;
      final source = ClientUpdateSource(
        baseUrl: session.endpoint.baseUrl,
        accessToken: session.accessToken,
        isCurrent: () =>
            !_disposed &&
            _account.isCurrent(generation) &&
            identical(_account.session, session),
      );
      final update = ClientUpdateController(
        ref.read(clientUpdateApiProvider),
        source,
      );
      _boundSession = session;
      _update = update;
      update.addListener(_updated);
      update.setVisible(true);
      await update.refreshSnapshot();
      if (!_current(operation, epoch)) return;
      if (update.snapshot?.supported != true) {
        throw const ClientUpdateException(ClientUpdateFailure.unsupported);
      }
      final repository = ref.read(clientReleaseFactoryProvider)(source);
      _repository = repository;
      try {
        final release = await repository.latest();
        if (!_current(operation, epoch)) return;
        _available = release;
        _checked = true;
      } finally {
        repository.close();
        if (identical(repository, _repository)) _repository = null;
      }
    } catch (error) {
      if (_current(operation, epoch)) _error = _failure(error);
    } finally {
      if (_current(operation, epoch)) setState(() => _checking = false);
    }
  }

  bool _current(int operation, int epoch) =>
      mounted &&
      !_disposed &&
      _active &&
      operation == _operation &&
      sessionCurrent(epoch);

  Future<void> _act(
    Future<void> Function(ClientUpdateController) action,
  ) async {
    final update = _update;
    if (!_active || !_signedIn || update == null || update.busy) return;
    final operation = _operation;
    final epoch = sessionGeneration;
    setState(() => _error = null);
    update.setVisible(true);
    try {
      await action(update);
    } catch (error) {
      if (_current(operation, epoch)) setState(() => _error = _failure(error));
    }
  }

  ClientUpdateFailure _failure(Object error) => error is ClientUpdateException
      ? error.failure
      : error is LarenorServerException
      ? ClientUpdateFailure.authentication
      : ClientUpdateFailure.unavailable;

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final update = _update;
    final release = _available;
    final snapshot = update?.snapshot;
    final compatible = release != null && snapshot?.accepts(release) == true;
    final busy = _checking || update?.busy == true;
    final enabled = _active && _signedIn && !busy;
    final text = !_signedIn
        ? l10n.clientUpdatesAccountRequired
        : _checking
        ? l10n.clientUpdatesChecking
        : switch (update?.phase) {
            ClientUpdatePhase.downloading => l10n.clientUpdatesDownloading,
            ClientUpdatePhase.verifying => l10n.clientUpdatesVerifying,
            ClientUpdatePhase.ready => l10n.clientUpdatesReady,
            ClientUpdatePhase.installing ||
            ClientUpdatePhase.systemPromptOpened =>
              l10n.clientUpdatesInstallerOpened,
            _ =>
              !_checked
                  ? l10n.clientUpdatesNotChecked
                  : release == null
                  ? l10n.clientUpdatesNoRelease
                  : compatible
                  ? l10n.clientUpdatesAvailable
                  : release.versionCode <= (snapshot?.versionCode ?? 0)
                  ? l10n.clientUpdatesCurrent
                  : l10n.clientUpdatesIncompatible,
          };
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: widget.onExit == null
            ? null
            : CupertinoNavigationBarBackButton(onPressed: widget.onExit),
        middle: Text(l10n.clientUpdatesTitle),
      ),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                SettingsSection(
                  footer: Text(l10n.clientUpdatesSafety),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(text, style: AppText.headline),
                          ),
                          if (snapshot?.supported == true) ...[
                            const SizedBox(height: 12),
                            Text(
                              '${l10n.clientUpdatesInstalled}: ${snapshot!.versionName} (${snapshot.versionCode})',
                            ),
                          ],
                          if (release != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              '${l10n.clientUpdatesNewVersion}: ${release.versionName} (${release.versionCode})',
                            ),
                            Text(
                              '${(release.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                            ),
                          ],
                          if (busy) ...[
                            const SizedBox(height: 16),
                            const CupertinoActivityIndicator(),
                          ],
                          if (update?.transfer
                              case final ClientUpdateProgress progress) ...[
                            const SizedBox(height: 12),
                            Text(
                              '${(100 * progress.receivedBytes / progress.totalBytes).floor()}%',
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _errorText(l10n, _error!),
                                style: TextStyle(
                                  color: CupertinoColors.systemRed.resolveFrom(
                                    context,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _button(
                      l10n.clientUpdatesCheck,
                      'updates-check',
                      enabled ? _check : null,
                    ),
                    if (compatible &&
                        update?.staged == null &&
                        update?.phase != ClientUpdatePhase.systemPromptOpened)
                      _button(
                        l10n.clientUpdatesDownload,
                        'updates-download',
                        enabled ? () => _act((u) => u.download(release)) : null,
                      ),
                    if (update?.staged != null)
                      _button(
                        l10n.clientUpdatesInstall,
                        'updates-install',
                        enabled
                            ? () => _act((u) async {
                                await u.install();
                              })
                            : null,
                      ),
                    if (update?.busy == true &&
                        {
                          ClientUpdatePhase.downloading,
                          ClientUpdatePhase.verifying,
                        }.contains(update?.phase))
                      _button(
                        l10n.commonCancel,
                        'updates-cancel',
                        _active
                            ? () async {
                                await update!.cancel();
                              }
                            : null,
                      ),
                  ],
                ),
                if (_signedIn &&
                    snapshot?.supported == true &&
                    snapshot?.canRequestPackageInstalls == false)
                  SettingsSection(
                    footer: Text(l10n.clientUpdatesPermissionHint),
                    children: [
                      _button(
                        l10n.clientUpdatesPermission,
                        'updates-permission',
                        enabled
                            ? () => _act((u) => u.openInstallPermission())
                            : null,
                      ),
                    ],
                  ),
                if (release?.releaseNotes.isNotEmpty == true)
                  SettingsSection(
                    header: Text(l10n.clientUpdatesReleaseNotes),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(release!.releaseNotes),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(String text, String key, Future<void> Function()? action) =>
      SizedBox(
        width: double.infinity,
        child: CupertinoButton(
          key: ValueKey(key),
          onPressed: action,
          child: Text(text, textAlign: TextAlign.center),
        ),
      );

  String _errorText(
    AppLocalizations l10n,
    ClientUpdateFailure error,
  ) => switch (error) {
    ClientUpdateFailure.unsupported => l10n.clientUpdatesUnsupported,
    ClientUpdateFailure.incompatible => l10n.clientUpdatesIncompatible,
    ClientUpdateFailure.verification ||
    ClientUpdateFailure.invalidMetadata => l10n.clientUpdatesVerificationError,
    ClientUpdateFailure.authentication ||
    ClientUpdateFailure.permission ||
    ClientUpdateFailure.expired => l10n.clientUpdatesSessionError,
    ClientUpdateFailure.installPermission => l10n.clientUpdatesPermissionHint,
    ClientUpdateFailure.cancelled => l10n.clientUpdatesCancelled,
    _ => l10n.clientUpdatesNetworkError,
  };
}
