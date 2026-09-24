import 'dart:async';
import 'dart:convert';

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
import '../../data/larenor_server_api.dart';
import '../../providers/server_providers.dart';
import '../data/server_core_backups_controller.dart';
import '../domain/server_core_backup_models.dart';
import 'server_core_backup_file_access.dart';
import 'server_core_backup_source_access.dart';

/// A bounded encrypted-export and manifest-preflight surface. Restoring a
/// running Core is intentionally not exposed; empty-Core recovery stays a
/// server-owned operation.
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
  late final ServerCoreBackupFileAccess _files;
  late final ServerCoreBackupSourceAccess _sources;
  late final int _accountEpoch;
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true, _expired = false, _loaded = false, _pinReady = false;
  bool _wasCurrent = true;
  bool _invalidPassphrase = false;
  bool _choosingDestination = false;
  LarenorRequestSecret? _pendingPassphrase;
  _BackupNotice? _notice;

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
    _files = ref.read(serverCoreBackupFileAccessProvider).scoped();
    _sources = ref.read(serverCoreBackupSourceAccessProvider).scoped();
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
  void clearPendingInteraction() {
    if (_choosingDestination &&
        !foreground &&
        interactionActive &&
        !sessionExpired &&
        _account.isCurrent(_accountEpoch)) {
      _clearPassphrase();
      return;
    }
    _expire();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
    _clearPassphrase();
    _pendingPassphrase?.dispose();
    _pendingPassphrase = null;
    if (_files.hasPendingOperation) unawaited(_files.cancelPending());
    _backups.invalidate();
  }

  void _clearPassphrase() {
    _passphrase.clear();
    _confirmation.clear();
    _invalidPassphrase = false;
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _clearPassphrase();
    _pendingPassphrase?.dispose();
    _pendingPassphrase = null;
    if (_files.hasPendingOperation) unawaited(_files.cancelPending());
    _passphrase.dispose();
    _confirmation.dispose();
    _backups.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  Future<void> _load() async {
    if (!_active || _backups.busy || _backups.actionBusy) return;
    await _backups.load(current: _capture());
  }

  bool _validPassphrase(String value) =>
      value.length >= 16 &&
      value.length <= 128 &&
      utf8.encode(value).length <= 512 &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  LarenorRequestSecret? _takePassphrase() {
    final value = _passphrase.text;
    if (!_validPassphrase(value) || value != _confirmation.text) return null;
    return LarenorRequestSecret.coreBackup(value);
  }

  Future<void> _export() async {
    if (!_active || _backups.busy || _backups.actionBusy) return;
    final passphrase = _takePassphrase();
    if (passphrase == null) {
      setState(() {
        _invalidPassphrase = true;
        _notice = null;
      });
      return;
    }
    setState(() {
      _invalidPassphrase = false;
      _notice = null;
    });
    _clearPassphrase();
    _pendingPassphrase = passphrase;
    _choosingDestination = true;
    try {
      final destination = await _files.open(CoreBackupExport.filename);
      _choosingDestination = false;
      if (!identical(_pendingPassphrase, passphrase) ||
          destination == null ||
          !_active) {
        passphrase.dispose();
        await destination?.cancel();
        if (mounted && _active && destination == null) {
          setState(() => _notice = _BackupNotice.cancelled);
        }
        return;
      }
      _pendingPassphrase = null;
      final current = _capture();
      final exported = await _backups.export(
        passphrase,
        destination,
        current: current,
      );
      if (exported == null || !current()) return;
      setState(() {
        _notice = _BackupNotice.saved;
      });
    } catch (_) {
      passphrase.dispose();
      _pendingPassphrase = null;
      _choosingDestination = false;
      if (!mounted || !_active) return;
      setState(() => _notice = _BackupNotice.failed);
    }
  }

  Future<void> _preflight(CoreBackupManifest manifest) async {
    if (!_active || _backups.busy || _backups.actionBusy) return;
    setState(() => _notice = null);
    await _backups.preflight(manifest, current: _capture());
  }

  Future<void> _inspectSource() async {
    if (!_active ||
        _backups.busy ||
        _backups.actionBusy ||
        _backups.sourceBusy) {
      return;
    }
    setState(() => _notice = null);
    await _backups.inspectSource(
      inspect: _sources.inspect,
      cancel: _sources.cancelPending,
      current: _capture(),
    );
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
                          onPressed:
                              !_backups.busy &&
                                  !_backups.actionBusy &&
                                  !_backups.sourceBusy
                              ? _load
                              : null,
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
                    _sourceInspectionSection(l10n),
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
                    if (_backups.plan?.manifest case final manifest?) ...[
                      _exportSection(l10n),
                      _preflightSection(l10n, manifest),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _exportSection(AppLocalizations l10n) => SettingsSection(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    header: Text(l10n.serverBackupsExportTitle),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(l10n.serverBackupsPassphraseHint),
      ),
      _secretField(
        label: l10n.serverBackupsPassphrase,
        key: 'server-backups-passphrase',
        controller: _passphrase,
      ),
      _secretField(
        label: l10n.serverBackupsConfirmPassphrase,
        key: 'server-backups-confirm-passphrase',
        controller: _confirmation,
        done: true,
      ),
      if (_invalidPassphrase)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(l10n.serverBackupsPassphraseInvalid),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: CupertinoButton(
            key: const ValueKey('server-backups-export'),
            onPressed:
                !_backups.busy && !_backups.actionBusy && !_backups.sourceBusy
                ? _export
                : null,
            child: Text(l10n.serverBackupsExport),
          ),
        ),
      ),
      if (_backups.actionBusy)
        const Padding(
          padding: EdgeInsets.all(16),
          child: CupertinoActivityIndicator(),
        ),
      if (_backups.actionFailure != null || _notice != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _backups.actionFailure != null
                  ? l10n.serverBackupsActionFailed
                  : switch (_notice!) {
                      _BackupNotice.saved => l10n.serverBackupsExportSaved,
                      _BackupNotice.cancelled =>
                        l10n.serverBackupsExportCancelled,
                      _BackupNotice.failed => l10n.serverBackupsActionFailed,
                    },
            ),
          ),
        ),
    ],
  );

  Widget _sourceInspectionSection(AppLocalizations l10n) {
    final proof = _backups.sourceInspection;
    return SettingsSection(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      header: Text(l10n.serverBackupsSourceInspectionTitle),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.serverBackupsSourceInspectionHint),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: CupertinoButton(
              key: const ValueKey('server-backups-source-inspect'),
              onPressed:
                  !_backups.busy && !_backups.actionBusy && !_backups.sourceBusy
                  ? _inspectSource
                  : null,
              child: Text(l10n.serverBackupsSourceInspect),
            ),
          ),
        ),
        if (_backups.sourceBusy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
        if (_backups.sourceFailure != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(
              liveRegion: true,
              child: Text(l10n.serverBackupsSourceInspectionFailed),
            ),
          ),
        if (proof != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _row(
                    l10n.serverBackupsSourceMagic,
                    l10n.serverBackupsSourceMagicVerified,
                  ),
                  _row(l10n.serverBackupsSourceSize, _size(proof.byteLength)),
                  _row(l10n.serverBackupsSourceSha256, proof.sha256),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _secretField({
    required String label,
    required String key,
    required TextEditingController controller,
    bool done = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppText.subhead),
        const SizedBox(height: 8),
        Semantics(
          label: label,
          textField: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: CupertinoTextField(
              key: ValueKey(key),
              controller: controller,
              obscureText: true,
              maxLength: 128,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: done
                  ? TextInputAction.done
                  : TextInputAction.next,
              padding: const EdgeInsets.all(12),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _preflightSection(AppLocalizations l10n, CoreBackupManifest manifest) {
    final result = _backups.compatibility;
    return SettingsSection(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      header: Text(l10n.serverBackupsPreflightTitle),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.serverBackupsPreflightHint),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: CupertinoButton(
              key: const ValueKey('server-backups-preflight'),
              onPressed:
                  !_backups.busy && !_backups.actionBusy && !_backups.sourceBusy
                  ? () => _preflight(manifest)
                  : null,
              child: Text(l10n.serverBackupsPreflight),
            ),
          ),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    result.compatible
                        ? l10n.serverBackupsPreflightCompatible
                        : l10n.serverBackupsPreflightIncompatible,
                  ),
                  if (!result.compatible) ...[
                    const SizedBox(height: 12),
                    for (final reason in result.reasons)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(_reasonLabel(l10n, reason)),
                      ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _reasonLabel(
    AppLocalizations l10n,
    CoreBackupCompatibilityReason reason,
  ) => switch (reason) {
    CoreBackupCompatibilityReason.unsupportedContract =>
      l10n.serverBackupsMismatchContract,
    CoreBackupCompatibilityReason.databaseSchema =>
      l10n.serverBackupsMismatchDatabase,
    CoreBackupCompatibilityReason.coreVersion => l10n.serverBackupsMismatchCore,
    CoreBackupCompatibilityReason.componentSchema =>
      l10n.serverBackupsMismatchComponent,
    CoreBackupCompatibilityReason.componentVersion =>
      l10n.serverBackupsMismatchComponentVersion,
    CoreBackupCompatibilityReason.componentVolume =>
      l10n.serverBackupsMismatchComponentVolume,
  };

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
          if (manifest.consistencyBoundary case final boundary?) ...[
            _row(
              l10n.serverBackupsManagedComponents,
              '${manifest.components.length}',
            ),
            _row(
              l10n.serverBackupsManagedVolumes,
              '${manifest.components.fold<int>(0, (total, item) => total + item.volumeResourceIds.length)}',
            ),
            _row(
              l10n.serverBackupsConsistencyBoundary,
              l10n.serverBackupsConsistencyValue(boundary.maxDurationSeconds),
            ),
          ],
          for (final resource in manifest.resources)
            _row(_resourceLabel(l10n, resource), _size(resource.byteLength)),
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

  String _resourceLabel(AppLocalizations l10n, CoreBackupResource resource) =>
      resource.id != 'component-index' &&
          resource.kind == CoreBackupResourceKind.componentData
      ? l10n.serverBackupsManagedVolumes
      : switch (resource.kind) {
          CoreBackupResourceKind.database => l10n.serverBackupsDatabase,
          CoreBackupResourceKind.vaultKey => l10n.serverBackupsVaultKey,
          CoreBackupResourceKind.configuration =>
            l10n.serverBackupsConfiguration,
          CoreBackupResourceKind.componentData => l10n.serverBackupsComponents,
          CoreBackupResourceKind.familyBoard => l10n.serverBackupsFamilyBoard,
        };

  String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

enum _BackupNotice { saved, cancelled, failed }
