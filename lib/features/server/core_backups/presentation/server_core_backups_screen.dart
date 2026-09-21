import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_core_backups_controller.dart';
import '../domain/server_core_backup_models.dart';

/// A read-only readiness surface. Restoring a running Core is intentionally not
/// exposed; encrypted bundles are restored into an empty Core by the Server.
class ServerCoreBackupsScreen extends ConsumerStatefulWidget {
  const ServerCoreBackupsScreen({super.key});

  @override
  ConsumerState<ServerCoreBackupsScreen> createState() =>
      _ServerCoreBackupsScreenState();
}

class _ServerCoreBackupsScreenState
    extends MediaSessionState<ServerCoreBackupsScreen> {
  late final ServerAccountController _account;
  late final ServerCoreBackupsController _backups;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _loaded = false, _pinReady = false;
  bool _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _backups = ServerCoreBackupsController(_account);
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.working ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
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
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted || _expired) return;
    final wasBusy = _backups.busy;
    _expired = true;
    sessionGeneration++;
    _backups.invalidate();
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _backups.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  Future<void> _load() async {
    if (!_active || _backups.busy) return;
    await _backups.load(current: _capture());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) unawaited(_load());
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.serverBackupsTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _backups,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l10n.serverOpenFromSettings
                        : l10n.serverFailurePermission,
                  ),
                ),
              );
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(l10n.serverBackupsIntro),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: CupertinoButton(
                          key: const ValueKey('server-backups-refresh'),
                          onPressed: !_backups.busy ? _load : null,
                          child: Text(l10n.commonRefresh),
                        ),
                      ),
                    ),
                    if (_backups.busy)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_backups.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(l10n.serverFailureConnection),
                        ),
                      ),
                    if (_backups.plan case final plan?) _plan(l10n, plan),
                    SettingsSection(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      header: Text(l10n.serverBackupsOfflineRestoreTitle),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(l10n.serverBackupsOfflineRestoreHint),
                        ),
                      ],
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

  Widget _plan(AppLocalizations l10n, CoreBackupPlan plan) {
    final manifest = plan.manifest;
    return SettingsSection(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      header: Semantics(
        liveRegion: true,
        header: true,
        child: Text(
          plan.ready ? l10n.serverBackupsReady : l10n.serverBackupsBlocked,
        ),
      ),
      children: [
        if (manifest == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.serverBackupsBlockedHint(plan.blockers.length)),
          )
        else ...[
          _row(
            l10n.serverBackupsCreated,
            DateFormat.yMd(l10n.localeName)
                .add_Hm()
                .format(manifest.createdAt.toLocal()),
          ),
          _row(l10n.serverBackupsCoreVersion, manifest.coreVersion),
          _row(
            l10n.serverBackupsDatabaseVersion,
            '${manifest.databaseSchemaVersion}',
          ),
          _row(l10n.serverBackupsIncluded, _size(manifest.totalBytes)),
          for (final resource in manifest.resources)
            _row(
              _resourceLabel(l10n, resource.kind),
              _size(resource.byteLength),
            ),
        ],
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppText.body)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  String _resourceLabel(AppLocalizations l10n, CoreBackupResourceKind kind) =>
      switch (kind) {
        CoreBackupResourceKind.database => l10n.serverBackupsDatabase,
        CoreBackupResourceKind.vaultKey => l10n.serverBackupsVaultKey,
        CoreBackupResourceKind.configuration => l10n.serverBackupsConfiguration,
        CoreBackupResourceKind.componentData => l10n.serverBackupsComponents,
        CoreBackupResourceKind.familyBoard => l10n.serverBackupsFamilyBoard,
      };

  String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
