import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/home_session_controller.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../backup/data/backup_snapshot.dart';
import '../../backup/data/backup_repository.dart';
import '../../backup/data/backup_restore_access_provider.dart';
import '../../backup/presentation/backup_screen.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/server_account_controller.dart';
import '../data/server_vault_controller.dart';
import '../domain/server_models.dart';
import '../providers/server_providers.dart';

/// Settings owns the PIN gate. A fresh-install route additionally fails closed
/// if a PIN appears. Both routes discard reviews when their PIN source changes.
class ServerVaultScreen extends ConsumerStatefulWidget {
  const ServerVaultScreen({super.key, this.freshInstall = false});
  final bool freshInstall;
  @override
  ConsumerState<ServerVaultScreen> createState() => _ServerVaultScreenState();
}

class _ServerVaultScreenState extends MediaSessionState<ServerVaultScreen> {
  late final ServerAccountController _account;
  late final HomeSessionController? _home;
  late final BackupRepository _repository;
  ProviderContainer? _container;
  late final ServerVaultController _vault;
  late final int _accountGeneration;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true;
  bool _wasCurrent = true;
  bool _pinResolved = false;
  bool _pinBound = false;
  bool _pinChanged = false;
  String? _initialPin;
  bool _busy = false;
  bool _handedOff = false;
  bool _settings = true;
  bool _dashboard = true;
  bool _connections = false;
  ServerVaultDirection _direction = ServerVaultDirection.restore;
  BackupConflictPolicy _conflict = BackupConflictPolicy.keepExisting;
  ServerVaultReview? _review;
  Route<bool>? _dialog;
  String? _message;
  bool _error = false;
  bool _scopeChanged = false;

  bool get _sameScope =>
      identical(ref.read(serverAccountControllerProvider), _account) &&
      identical(ref.read(homeSessionControllerProvider), _home) &&
      identical(ref.read(backupRepositoryProvider), _repository) &&
      identical(ProviderScope.containerOf(context, listen: false), _container);

  bool get _active =>
      sessionCurrent(sessionGeneration) &&
      !_scopeChanged &&
      _sameScope &&
      _visible &&
      _pinResolved &&
      !_pinChanged &&
      (!widget.freshInstall || _initialPin == null) &&
      (ModalRoute.of(context)?.isCurrent == true ||
          _dialog?.isCurrent == true) &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.mustChangePassword == false;
  bool get _enabled => _active && !_busy && !_vault.busy && !_handedOff;
  BackupSelection get _selection => BackupSelection(
    settings: _settings,
    dashboard: _dashboard,
    connections: _connections,
  );

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _home = ref.read(homeSessionControllerProvider);
    _repository = ref.read(backupRepositoryProvider);
    _accountGeneration = _account.generation;
    _vault = ServerVaultController(
      account: _account,
      repository: _repository,
      isCurrent: () => _active,
    );
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!mounted) return;
    if (!_account.isCurrent(_accountGeneration) ||
        _account.working ||
        _account.session?.user.mustChangePassword != false) {
      _invalidate();
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
    if (!_sameScope && !_scopeChanged) {
      _scopeChanged = true;
      _invalidate(deferDialogRemoval: true);
    }
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current && _dialog == null) _invalidate();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    if (!mounted) return;
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _invalidate();
    setState(() {});
  }

  @override
  void clearPendingInteraction() => _invalidate();

  void _invalidate({bool deferDialogRemoval = false}) {
    final wasBusy = _busy;
    sessionGeneration++;
    _vault.invalidate();
    _review = null;
    _message = null;
    _busy = false;
    _connections = false;
    final route = _dialog;
    _dialog = null;
    void removeDialog() {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    }

    if (deferDialogRemoval) {
      WidgetsBinding.instance.addPostFrameCallback((_) => removeDialog());
    } else {
      removeDialog();
    }
    // Only an owned transfer can have initiated this token refresh. Stop a
    // refresh that is waiting to send, without issuing a remote logout.
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    _invalidate();
    _vault.dispose();
    _ticker?.removeListener(_visibilityChanged);
    super.dispose();
  }

  VoidCallback _callback(VoidCallback action) {
    final epoch = sessionGeneration;
    return () {
      if (_enabled && sessionCurrent(epoch)) action();
    };
  }

  Future<void> _prepare() async {
    if (!_enabled || _selection.isEmpty) return;
    final epoch = sessionGeneration;
    setState(() {
      _busy = true;
      _message = null;
      _review = null;
    });
    try {
      final access = _direction == ServerVaultDirection.restore
          ? await ref.read(backupRestoreAccessFactoryProvider)(
              expectedPin: _initialPin,
              isCurrent: () => sessionCurrent(epoch) && _active,
            )
          : null;
      if (!sessionCurrent(epoch) || !_active) return;
      final review = await _vault.prepare(
        direction: _direction,
        selection: _selection,
        conflictPolicy: _conflict,
        access: access,
      );
      if (!sessionCurrent(epoch) || !_active) return;
      setState(() {
        _review = review;
        _settings = review.selection.settings;
        _dashboard = review.selection.dashboard;
        _connections = review.selection.connections;
      });
    } catch (error) {
      if (sessionCurrent(epoch) && _active) _showFailure(error);
    } finally {
      if (mounted) {
        setState(() {
          if (sessionCurrent(epoch)) _busy = false;
        });
      }
    }
  }

  void _showFailure(Object error, {bool uploading = false}) {
    final l10n = AppLocalizations.of(context);
    final code = switch (error) {
      LarenorServerException() => error.code,
      BackupException() => error.code,
      _ => '',
    };
    setState(() {
      _review = null;
      _error = true;
      _message = switch (code) {
        'conflict' || 'revision_conflict' => l10n.serverVaultConflict,
        'review_expired' ||
        'cancelled' ||
        'restore_expired' ||
        'restore_changed' => l10n.serverVaultExpired,
        'ha_connection_pending' => l10n.backupHaConnectionPending,
        'connection_pending' => l10n.backupConnectionPending,
        'restore_target_mismatch' => l10n.backupRestoreDirectTarget,
        'empty_selection' => l10n.backupSelectGroup,
        'empty_vault' => l10n.serverVaultEmpty,
        'unauthorized' => l10n.serverFailureAuthentication,
        'forbidden' ||
        'password_change_required' => l10n.serverFailurePermission,
        _ =>
          uploading ? l10n.serverVaultWriteUnknown : l10n.serverVaultReadFailed,
      };
    });
  }

  Future<void> _confirm() async {
    final review = _review;
    if (!_enabled || review == null || _dialog != null) return;
    final epoch = sessionGeneration;
    final l10n = AppLocalizations.of(context);
    final uploading = review.direction == ServerVaultDirection.upload;
    setState(() => _busy = true); // Own the entire modal, not only the write.
    late final CupertinoDialogRoute<bool> route;
    route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (context) {
        if (ModalRoute.isCurrentOf(context) != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(_dialog, route) && !route.isCurrent) {
              setState(_invalidate);
            }
          });
        }
        return CupertinoAlertDialog(
          title: Text(
            uploading ? l10n.serverVaultConfirmUpload : l10n.backupApplyTitle,
          ),
          content: Text(
            '${l10n.serverVaultRevision(review.revision)}\n\n'
            '${uploading ? l10n.serverVaultReplaceHint : l10n.backupApplyMessage}',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                if (routeIsCurrent(epoch)) Navigator.of(context).pop(false);
              },
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              key: const ValueKey('server-vault-confirm'),
              isDestructiveAction:
                  uploading ||
                  review.conflictPolicy == BackupConflictPolicy.replaceSelected,
              onPressed: () {
                if (routeIsCurrent(epoch)) Navigator.of(context).pop(true);
              },
              child: Text(
                uploading ? l10n.serverVaultUpload : l10n.backupApply,
              ),
            ),
          ],
        );
      },
    );
    _dialog = route;
    PreparedBackupRestore? prepared;
    try {
      final confirmed = await Navigator.of(context).push(route);
      if (identical(_dialog, route)) _dialog = null;
      if (!sessionCurrent(epoch) || !_active) return;
      if (confirmed != true) {
        _vault.invalidate();
        setState(() => _review = null);
        return;
      }
      if (uploading) {
        await _vault.upload(review);
        if (!sessionCurrent(epoch) || !_active) return;
        setState(() {
          _review = null;
          _message = l10n.serverVaultUploaded;
          _error = false;
        });
      } else {
        prepared = await _vault.takeRestore(review);
        if (!mounted || !sessionCurrent(epoch) || !_active) return;
        final handler = ref.read(preparedBackupRestoreHandlerProvider);
        await handler(context, prepared, l10n);
        _handedOff = prepared.wasHandedOff;
        // The boundary owns success/failure. The old provider tree is gone.
      }
    } catch (error) {
      _handedOff = prepared?.wasHandedOff ?? _handedOff;
      if (!_handedOff && sessionCurrent(epoch) && _active) {
        _showFailure(error, uploading: uploading);
      }
    } finally {
      _handedOff = prepared?.wasHandedOff ?? _handedOff;
      prepared?.retire();
      if (!_handedOff && mounted) {
        setState(() {
          if (sessionCurrent(epoch)) _busy = false;
        });
      }
    }
  }

  bool routeIsCurrent(int epoch) =>
      sessionCurrent(epoch) && _active && _dialog?.isCurrent == true;

  void _resetReview() {
    _vault.invalidate();
    _review = null;
    _message = null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinResolved = !pin.isLoading && !pin.hasError;
    if (_pinResolved && !_pinBound) {
      _pinBound = true;
      _initialPin = pin.value;
    }
    ref.listen(pinLockProvider, (_, next) {
      final resolved = !next.isLoading && !next.hasError;
      if (!resolved || (_pinBound && next.value != _initialPin)) {
        if (resolved) _pinChanged = true;
        _pinResolved = resolved;
        _invalidate();
      }
    });
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.serverVaultTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: !_active
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.serverOpenFromSettings),
                ),
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 780),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _note(l10n.serverVaultIntro),
                        _note(l10n.serverVaultFilesExcluded),
                        _choice(
                          'server-vault-upload-mode',
                          l10n.serverVaultUpload,
                          _direction == ServerVaultDirection.upload,
                          () => setState(() {
                            _direction = ServerVaultDirection.upload;
                            _resetReview();
                          }),
                        ),
                        _choice(
                          'server-vault-restore-mode',
                          l10n.serverVaultRestore,
                          _direction == ServerVaultDirection.restore,
                          () => setState(() {
                            _direction = ServerVaultDirection.restore;
                            _resetReview();
                          }),
                        ),
                        SettingsSection(
                          children: [
                            _group(
                              'server-vault-settings',
                              l10n.backupSettings,
                              _settings,
                              (v) => _settings = v,
                            ),
                            _group(
                              'server-vault-dashboard',
                              l10n.backupDashboard,
                              _dashboard,
                              (v) => _dashboard = v,
                            ),
                            _group(
                              'server-vault-connections',
                              l10n.backupConnections,
                              _connections,
                              (v) => _connections = v,
                            ),
                          ],
                        ),
                        _note(l10n.backupCredentialHint),
                        if (_direction == ServerVaultDirection.upload)
                          _note(l10n.serverVaultReplaceHint)
                        else ...[
                          _note(l10n.backupConflicts),
                          _choice(
                            'server-vault-keep',
                            l10n.backupKeepExisting,
                            _conflict == BackupConflictPolicy.keepExisting,
                            () => setState(() {
                              _conflict = BackupConflictPolicy.keepExisting;
                              _resetReview();
                            }),
                          ),
                          _choice(
                            'server-vault-replace',
                            l10n.backupReplaceSelected,
                            _conflict == BackupConflictPolicy.replaceSelected,
                            () => setState(() {
                              _conflict = BackupConflictPolicy.replaceSelected;
                              _resetReview();
                            }),
                          ),
                          _note(l10n.backupConflictHint),
                        ],
                        if (_review case final review?) ...[
                          _note(l10n.serverVaultRevision(review.revision)),
                          _preview(l10n.serverVaultLocal, review.local),
                          if (review.remote case final remote?)
                            _preview(l10n.serverVaultRemote, remote)
                          else
                            _note(l10n.serverVaultEmpty),
                          _note(l10n.backupPrivacyPolicyHint),
                          if (review.remote?.requiresPrivacyReview == true ||
                              review.local.requiresPrivacyReview)
                            _note(l10n.backupPrivacyReviewRequired),
                          if (_connections &&
                              review.remote?.requiresCertificateReview == true)
                            _note(l10n.backupCertificateReview),
                          _button(
                            'server-vault-apply',
                            _direction == ServerVaultDirection.upload
                                ? l10n.serverVaultUpload
                                : l10n.backupApply,
                            _confirm,
                          ),
                          CupertinoButton(
                            onPressed: _enabled
                                ? _callback(() => setState(_resetReview))
                                : null,
                            child: Text(l10n.commonCancel),
                          ),
                        ] else
                          _button(
                            'server-vault-review',
                            l10n.serverVaultReview,
                            _selection.isEmpty ? null : _prepare,
                          ),
                        if (_busy && _dialog == null)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CupertinoActivityIndicator()),
                          ),
                        if (_message case final message?)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                message,
                                style: TextStyle(
                                  color: _error
                                      ? CupertinoColors.systemRed.resolveFrom(
                                          context,
                                        )
                                      : CupertinoColors.label.resolveFrom(
                                          context,
                                        ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _note(String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Text(
      value,
      style: AppText.footnote.copyWith(
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    ),
  );

  Widget _choice(
    String key,
    String label,
    bool selected,
    VoidCallback action,
  ) => CupertinoButton(
    key: ValueKey(key),
    onPressed: _enabled ? _callback(action) : null,
    child: Row(
      children: [
        Icon(
          selected
              ? CupertinoIcons.checkmark_circle_fill
              : CupertinoIcons.circle,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    ),
  );

  Widget _group(
    String key,
    String label,
    bool selected,
    ValueChanged<bool> action,
  ) {
    final epoch = sessionGeneration;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 8),
          CupertinoSwitch(
            key: ValueKey(key),
            value: selected,
            onChanged: _enabled
                ? (value) {
                    if (!_enabled || !sessionCurrent(epoch)) return;
                    setState(() {
                      action(value);
                      _resetReview();
                    });
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _button(String key, String label, VoidCallback? action) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: CupertinoButton.filled(
      key: ValueKey(key),
      onPressed: _enabled && action != null ? _callback(action) : null,
      child: Text(label, textAlign: TextAlign.center),
    ),
  );

  Widget _preview(String title, BackupPreview preview) {
    final l10n = AppLocalizations.of(context);
    // Defense in depth: render only known identifiers, never a service payload.
    final services = preview.services
        .where(backupConnectionFields.containsKey)
        .join(', ');
    return SettingsSection(
      header: Text(title),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                DateFormat.yMMMd(Localizations.localeOf(context).toString())
                    .format(preview.createdAt.toLocal()),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.backupCountSummary(
                  preview.settingCount,
                  preview.roomCount,
                  preview.tileCount,
                  preview.favoriteCount,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${l10n.backupServices}: ${services.isEmpty ? l10n.backupNoServices : services}',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
