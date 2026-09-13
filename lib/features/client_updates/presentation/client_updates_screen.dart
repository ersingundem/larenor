import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
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
    final progress = update?.transfer;
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
    final statusText = _error == null ? text : _errorText(l10n, _error!);
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
                  header: Text(l10n.clientUpdatesStatus),
                  footer: Text(l10n.clientUpdatesSafety),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _UpdateStatusCard(
                            text: statusText,
                            error: _error != null,
                            busy: busy,
                            ready: update?.staged != null,
                          ),
                          if (snapshot?.supported == true ||
                              release != null) ...[
                            const SizedBox(height: 16),
                            _VersionOverview(
                              snapshot: snapshot,
                              release: release,
                            ),
                          ],
                          if (progress != null) ...[
                            const SizedBox(height: 16),
                            _TransferProgress(progress: progress),
                          ] else if (busy) ...[
                            const SizedBox(height: 16),
                            Semantics(
                              liveRegion: true,
                              label: statusText,
                              child: const CupertinoActivityIndicator(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _button(
                      l10n.clientUpdatesCheck,
                      'updates-check',
                      enabled ? _check : null,
                      icon: CupertinoIcons.arrow_clockwise,
                    ),
                    if (compatible &&
                        update?.staged == null &&
                        update?.phase != ClientUpdatePhase.systemPromptOpened)
                      _button(
                        l10n.clientUpdatesDownload,
                        'updates-download',
                        enabled ? () => _act((u) => u.download(release)) : null,
                        icon: CupertinoIcons.arrow_down_circle_fill,
                        primary: true,
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
                        icon: CupertinoIcons.device_phone_portrait,
                        primary: true,
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
                        icon: CupertinoIcons.xmark_circle,
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
                        icon: CupertinoIcons.lock_shield,
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

  Widget _button(
    String text,
    String key,
    Future<void> Function()? action, {
    required IconData icon,
    bool primary = false,
  }) => SizedBox(
    width: double.infinity,
    child: primary
        ? CupertinoButton.filled(
            key: ValueKey(key),
            minimumSize: const Size.fromHeight(48),
            borderRadius: BorderRadius.circular(12),
            onPressed: action,
            child: _ButtonLabel(icon: icon, text: text),
          )
        : CupertinoButton(
            key: ValueKey(key),
            minimumSize: const Size.fromHeight(48),
            onPressed: action,
            child: _ButtonLabel(icon: icon, text: text),
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

class _UpdateStatusCard extends StatelessWidget {
  const _UpdateStatusCard({
    required this.text,
    required this.error,
    required this.busy,
    required this.ready,
  });

  final String text;
  final bool error, busy, ready;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? CupertinoColors.systemRed
        : ready
        ? CupertinoColors.systemGreen
        : busy
        ? CupertinoColors.systemBlue
        : CupertinoColors.secondaryLabel;
    final icon = error
        ? CupertinoIcons.exclamationmark_circle_fill
        : ready
        ? CupertinoIcons.checkmark_circle_fill
        : busy
        ? CupertinoIcons.arrow_2_circlepath_circle_fill
        : CupertinoIcons.info_circle_fill;
    final resolved = color.resolveFrom(context);
    return Semantics(
      key: const ValueKey('updates-status-card'),
      container: true,
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: resolved.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: resolved, size: 24),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: AppText.headline)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VersionOverview extends StatelessWidget {
  const _VersionOverview({required this.snapshot, required this.release});

  final InstalledClientSnapshot? snapshot;
  final ClientRelease? release;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cards = <Widget>[
      if (snapshot?.supported == true)
        _VersionCard(
          key: const ValueKey('updates-installed-version'),
          label: l10n.clientUpdatesInstalled,
          version: '${snapshot!.versionName} (${snapshot!.versionCode})',
          icon: CupertinoIcons.device_phone_portrait,
        ),
      if (release != null)
        _VersionCard(
          key: const ValueKey('updates-available-version'),
          label: l10n.clientUpdatesNewVersion,
          version: '${release!.versionName} (${release!.versionCode})',
          detail: '${(release!.sizeBytes / 1048576).toStringAsFixed(1)} MB',
          icon: CupertinoIcons.cloud_download_fill,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final horizontal = constraints.maxWidth >= 520 && scale <= 1.3;
        return Flex(
          key: const ValueKey('updates-version-overview'),
          direction: horizontal ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: horizontal
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < cards.length; index++) ...[
              if (horizontal) Expanded(child: cards[index]) else cards[index],
              if (index != cards.length - 1)
                SizedBox(
                  width: horizontal ? 12 : 0,
                  height: horizontal ? 0 : 12,
                ),
            ],
          ],
        );
      },
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    super.key,
    required this.label,
    required this.version,
    required this.icon,
    this.detail,
  });

  final String label, version;
  final String? detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.mist.resolveFrom(context),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.footnote.copyWith(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 3),
                Text(version, style: AppText.headline),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail!, style: AppText.footnote),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _TransferProgress extends StatelessWidget {
  const _TransferProgress({required this.progress});
  final ClientUpdateProgress progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = (progress.receivedBytes / progress.totalBytes).clamp(
      0.0,
      1.0,
    );
    final percent = (value * 100).floor();
    return Semantics(
      key: const ValueKey('updates-transfer-progress'),
      container: true,
      liveRegion: true,
      label: l10n.clientUpdatesProgress,
      value: '$percent%',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.clientUpdatesProgress,
                    style: AppText.subhead,
                  ),
                ),
                Text('$percent%', style: AppText.headline),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey5.resolveFrom(context),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: value,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: CupertinoColors.activeBlue.resolveFrom(context),
                        borderRadius: BorderRadius.circular(4),
                      ),
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
}

class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      ExcludeSemantics(child: Icon(icon, size: 20)),
      const SizedBox(width: 8),
      Flexible(child: Text(text, textAlign: TextAlign.center)),
    ],
  );
}
