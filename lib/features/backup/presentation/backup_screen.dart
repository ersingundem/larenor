import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_providers.dart';
import '../data/backup_restore_access_provider.dart';

import 'package:intl/intl.dart';

import '../../../core/configuration_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/settings_file_dialog.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/backup_codec.dart';
import '../data/backup_repository.dart';
import '../data/backup_snapshot.dart';
import 'backup_file_access.dart';

final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepository(),
);
final backupCodecProvider = Provider<BackupCodec>((ref) => const BackupCodec());
final backupFileAccessProvider = Provider<BackupFileAccess>(
  (ref) => BackupFileAccess(),
);

typedef BackupRestoreHandler = Future<void> Function(
  BuildContext context,
  Future<void> Function() operation,
  AppLocalizations l10n,
);

final backupRestoreHandlerProvider = Provider<BackupRestoreHandler>(
  (ref) =>
      (context, operation, l10n) => ConfigurationScope.restore(
        context,
        operation: operation,
        progressLabel: l10n.backupProgress,
        failureLabel: l10n.backupRestoreFailed,
        continueLabel: l10n.backupContinue,
      ),
);

typedef PreparedBackupRestoreHandler = Future<void> Function(
  BuildContext context,
  PreparedBackupRestore prepared,
  AppLocalizations l10n,
);
final preparedBackupRestoreHandlerProvider =
    Provider<PreparedBackupRestoreHandler>(
      (ref) =>
          (context, prepared, l10n) => ConfigurationScope.restorePrepared(
            context,
            prepared: prepared,
            progressLabel: l10n.backupProgress,
            failureLabel: l10n.backupRestoreFailed,
            continueLabel: l10n.backupContinue,
          ),
    );

/// Configuration migration only: every mutation is to this device's storage.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({
    super.key,
    this.freshInstall = false,
    this.runFileDialog,
    this.gateCurrent,
  });

  final bool freshInstall;
  final bool Function()? gateCurrent;
  final SettingsFileDialogRunner? runFileDialog;

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen>
    with WidgetsBindingObserver {
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  final _restorePassphrase = TextEditingController();
  late final HomeSessionController? _home;
  PreparedBackupRestore? _prepared;
  bool _pinResolved = false;
  String? _pinValue;
  bool _focused = true;
  int? _viewId;
  bool _restoreMode = false;
  bool _settings = true;
  bool _dashboard = true;
  bool _connections = false;
  bool _busy = false;
  bool _fileDialog = false;
  bool _suspended = false;
  bool _foreground = true;
  int _generation = 0;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;
  Route<bool>? _applyConfirmation;
  bool get _interactive => _foreground && (_interaction?.active ?? true);
  bool _current({bool confirmation = false}) {
    if (!mounted ||
        !_interactive ||
        !_focused ||
        !identical(ref.read(homeSessionControllerProvider), _home) ||
        widget.gateCurrent?.call() == false ||
        !TickerMode.valuesOf(context).enabled) {
      return false;
    }
    final pin = ref.read(pinLockProvider);
    if (!_pinResolved ||
        pin.isLoading ||
        pin.hasError ||
        !pin.hasValue ||
        pin.value != _pinValue) {
      return false;
    }
    final window = ref.read(windowPolicySnapshotProvider);
    if (window.isLoading || window.hasError || !window.hasValue) return false;
    final value = window.requireValue;
    if (value.supported &&
        (!value.isResumed ||
            !value.hasWindowFocus ||
            value.isPictureInPicture)) {
      return false;
    }
    return ModalRoute.of(context)?.isCurrent == true ||
        confirmation && _applyConfirmation?.isCurrent == true;
  }

  void _homeChanged() {
    if (!mounted) return;
    _generation++;
    _clearSecrets();
    setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) {
      _generation++;
      _clearSecrets();
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    final ticking = TickerMode.valuesOf(context).enabled;
    if (!ticking) {
      _generation++;
      _clearSecrets();
    }
    _suspended = !_interactive || !ticking;
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    final hadScope = _interaction != null;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next;
    _interactionEpoch = next?.epoch ?? 0;
    next?.addListener(_interactionChanged);
    if (hadScope || !_interactive) {
      _generation++;
      _clearSecrets();
      _suspended = !_interactive;
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    final epoch = _interaction?.epoch ?? 0;
    if (epoch != _interactionEpoch) {
      _interactionEpoch = epoch;
      _generation++;
      _clearSecrets();
    }
    setState(() {
      if (!_interactive) _suspended = true;
      if (_interactive && !_fileDialog) _suspended = false;
    });
  }

  String? _message;
  bool _isError = false;
  Uint8List? _file;
  BackupSnapshot? _snapshot;
  BackupPreview? _preview;
  BackupConflictPolicy _conflict = BackupConflictPolicy.keepExisting;

  BackupSelection get _selection => BackupSelection(
    settings: _settings,
    dashboard: _dashboard,
    connections: _connections,
  );

  @override
  void initState() {
    super.initState();
    _home = ref.read(homeSessionControllerProvider);
    _home?.addListener(_homeChanged);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _restoreMode = widget.freshInstall;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) {
      _generation++;
      _clearSecrets();
      setState(() => _suspended = true);
    } else if (state == AppLifecycleState.resumed && !_fileDialog) {
      setState(() => _suspended = false);
    }
  }

  void _clearSecrets() {
    _prepared?.retire();
    _prepared = null;
    final route = _applyConfirmation;
    _applyConfirmation = null;
    if (route?.isActive == true) {
      void remove() {
        if (route?.isActive == true) route!.navigator?.removeRoute(route);
      }

      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) => remove());
      } else {
        remove();
      }
    }
    _passphrase.clear();
    _confirmation.clear();
    _restorePassphrase.clear();
    _snapshot = null;
    _preview = null;
  }

  @override
  void dispose() {
    _generation++;
    _prepared?.retire();
    _prepared = null;
    _home?.removeListener(_homeChanged);
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _file = null;
    _snapshot = null;
    _preview = null;
    _passphrase.dispose();
    _confirmation.dispose();
    _restorePassphrase.dispose();
    super.dispose();
  }

  Future<bool> _authorized() async {
    if (!mounted || !_interactive) return false;
    final generation = _generation;
    if (!widget.freshInstall) return true;
    final pin = await ref.read(pinLockStoreProvider).read();
    if (!mounted || !_interactive || generation != _generation) return false;
    if (pin == null) return true;
    _showMessage(AppLocalizations.of(context).backupLocked, error: true);
    return false;
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _isError = error;
    });
  }

  String _failure(
    Object error,
    AppLocalizations l10n, {
    bool decrypting = false,
  }) {
    if (error is BackupException &&
        {'restore_changed', 'restore_expired'}.contains(error.code)) {
      return l10n.backupRestoreReviewAgain;
    }
    if (error is BackupException && error.code == 'restore_target_mismatch') {
      return l10n.backupRestoreDirectTarget;
    }
    if (error is BackupException && error.code == 'ha_connection_pending') {
      return l10n.backupHaConnectionPending;
    }
    if (error is BackupException && error.code == 'connection_pending') {
      return l10n.backupConnectionPending;
    }
    if (error is BackupFileTooLarge ||
        error is BackupException && error.code == 'too_large') {
      return l10n.backupTooLarge;
    }
    return decrypting ? l10n.backupDecryptFailed : l10n.backupFailed;
  }

  Future<T?> _pickWithGate<T>(Future<T?> Function() operation) async {
    _fileDialog = true;
    try {
      final runner = widget.runFileDialog;
      return runner == null ? await operation() : await runner<T>(operation);
    } finally {
      _fileDialog = false;
      if (mounted) setState(() => _suspended = !_interactive);
    }
  }

  Future<void> _export() async {
    if (!mounted || !_interactive || _busy) return;
    final l10n = AppLocalizations.of(context);
    final passphrase = _passphrase.text;
    if (_selection.isEmpty) {
      _showMessage(l10n.backupSelectGroup, error: true);
      return;
    }
    if (passphrase.runes.length < 12) {
      _showMessage(l10n.backupPassphraseInvalid, error: true);
      return;
    }
    if (passphrase != _confirmation.text) {
      _showMessage(l10n.backupPassphraseMismatch, error: true);
      return;
    }
    final generation = _generation;
    final repository = ref.read(backupRepositoryProvider);
    final codec = ref.read(backupCodecProvider);
    final files = ref.read(backupFileAccessProvider);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final pin = await ref.read(pinLockStoreProvider).read();
      if (!mounted || generation != _generation) return;
      if (pin != null && passphrase == pin) {
        _showMessage(l10n.backupPassphraseSamePin, error: true);
        return;
      }
      BackupCodec.validatePassphrase(passphrase, settingsPin: pin);
      BackupSnapshot? snapshot = await repository.capture(_selection);
      if (!mounted || generation != _generation) return;
      final encrypted = await codec.encrypt(snapshot, passphrase);
      // Do not retain decrypted data while the system picker is open.
      snapshot = null;
      if (!mounted || generation != _generation) return;
      _passphrase.clear();
      _confirmation.clear();
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final result = await _pickWithGate(
        () => files.save(encrypted, 'larenor-$date.larenor-vault'),
      );
      if (!mounted) return;
      _showMessage(result == null ? l10n.backupCancelled : l10n.backupSaved);
    } catch (error) {
      if (mounted && generation == _generation) {
        _showMessage(_failure(error, l10n), error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseFile() async {
    if (!mounted || !_interactive || _busy) return;
    final l10n = AppLocalizations.of(context);
    final files = ref.read(backupFileAccessProvider);
    setState(() {
      _busy = true;
      _message = null;
      _file = null;
      _clearSecrets();
    });
    try {
      if (!await _authorized() || !mounted) return;
      final file = await _pickWithGate(files.pick);
      if (!mounted || !await _authorized()) return;
      if (file == null) {
        _showMessage(l10n.backupCancelled);
      } else {
        setState(() => _file = file);
      }
    } catch (error) {
      if (mounted) _showMessage(_failure(error, l10n), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decrypt() async {
    if (!mounted || !_interactive || _busy || _file == null) return;
    final l10n = AppLocalizations.of(context);
    final passphrase = _restorePassphrase.text;
    if (passphrase.runes.length < 12) {
      _showMessage(l10n.backupPassphraseInvalid, error: true);
      return;
    }
    final generation = _generation;
    final codec = ref.read(backupCodecProvider);
    final repository = ref.read(backupRepositoryProvider);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await _authorized() || !mounted || generation != _generation) return;
      final snapshot = await codec.decrypt(_file!, passphrase);
      if (!mounted || generation != _generation) return;
      final preview = await repository.preview(snapshot);
      if (!mounted || generation != _generation) return;
      setState(() {
        _snapshot = snapshot;
        _preview = preview;
        _settings = preview.hasSettings;
        _dashboard = preview.hasDashboard;
        _connections = false;
        _conflict = BackupConflictPolicy.keepExisting;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        _showMessage(_failure(error, l10n, decrypting: true), error: true);
      }
    } finally {
      if (mounted) {
        _restorePassphrase.clear();
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _apply() async {
    if (!mounted ||
        !_interactive ||
        _busy ||
        _snapshot == null ||
        _selection.isEmpty) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final generation = _generation;
    var handedOff = false;
    PreparedBackupRestore? prepared;
    setState(() => _busy = true);
    try {
      if (!await _authorized() || !mounted || generation != _generation) return;
      if (!_current()) return;
      final snapshot = BackupSnapshot.fromJson(_snapshot!.toJson());
      final selection = _selection, conflict = _conflict;
      final repository = ref.read(backupRepositoryProvider);
      final access = await ref.read(backupRestoreAccessFactoryProvider)(
        expectedPin: _pinValue,
        isCurrent: () =>
            mounted &&
            generation == _generation &&
            _current(confirmation: true),
      );
      if (!mounted || generation != _generation || !_current()) return;
      prepared = await repository.prepareRestore(
        snapshot,
        selection,
        conflictPolicy: conflict,
        access: access,
      );
      if (!mounted || generation != _generation || !_current()) {
        prepared.retire();
        return;
      }
      _prepared = prepared;
      final proposal = prepared;
      final route = CupertinoDialogRoute<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(l10n.backupApplyTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                proposal.targetsDirect
                    ? l10n.backupRestoreTargetDirect
                    : l10n.backupRestoreTargetDevice,
              ),
              const SizedBox(height: 8),
              Text(
                [
                  if (selection.settings) l10n.backupSettings,
                  if (selection.dashboard) l10n.backupDashboard,
                  if (selection.connections) l10n.backupConnections,
                ].join(' · '),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.backupRestoreFromBackup,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (selection.settings)
                Text(
                  l10n.backupRestorePreferenceCount(
                    proposal.summary.settingCount,
                  ),
                ),
              if (selection.dashboard)
                Text(
                  l10n.backupRestoreLayoutCount(
                    proposal.summary.roomCount,
                    proposal.summary.tileCount,
                    proposal.summary.favoriteCount,
                  ),
                ),
              if (selection.connections)
                Text(
                  l10n.backupRestoreConnectionCount(
                    proposal.summary.services.length,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                l10n.backupExistingData,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (selection.settings)
                Text(
                  l10n.backupRestorePreferenceCount(
                    proposal.summary.existingSettingsCount,
                  ),
                ),
              if (selection.dashboard)
                Text(
                  proposal.summary.existingDashboard
                      ? l10n.backupDashboard
                      : l10n.commonNone,
                ),
              if (selection.connections)
                Text(
                  l10n.backupRestoreConnectionCount(
                    proposal.summary.existingServices.length,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                conflict == BackupConflictPolicy.replaceSelected
                    ? l10n.backupReplaceSelected
                    : l10n.backupKeepExisting,
              ),
              const SizedBox(height: 8),
              Text(l10n.backupApplyMessage),
            ],
          ),
          actions: [
            _RestoreDialogAction(
              onPressed: () {
                if (context.mounted &&
                    ModalRoute.of(context)?.isCurrent == true) {
                  Navigator.pop(context, false);
                }
              },
              label: l10n.commonCancel,
            ),
            _RestoreDialogAction(
              isDestructiveAction:
                  conflict == BackupConflictPolicy.replaceSelected,
              onPressed: () {
                if (mounted &&
                    _current(confirmation: true) &&
                    generation == _generation &&
                    context.mounted &&
                    ModalRoute.of(context)?.isCurrent == true) {
                  Navigator.pop(context, true);
                }
              },
              label: l10n.backupApply,
            ),
          ],
        ),
      );
      _applyConfirmation = route;
      final accepted = await Navigator.of(context).push(route) ?? false;
      if (identical(_applyConfirmation, route)) _applyConfirmation = null;
      if (!mounted ||
          generation != _generation ||
          !accepted ||
          _snapshot == null) {
        return;
      }
      // A PIN could have been installed while the confirmation was open.
      if (!await _authorized() || !mounted || generation != _generation) return;
      if (!_current()) return;
      final restore = ref.read(preparedBackupRestoreHandlerProvider);
      await restore(context, prepared, l10n);
      handedOff = prepared.wasHandedOff;
    } catch (error) {
      if (!handedOff && mounted && generation == _generation) {
        _showMessage(_failure(error, l10n), error: true);
      }
    } finally {
      handedOff = prepared?.wasHandedOff ?? handedOff;
      prepared?.retire();
      if (!handedOff && mounted) setState(() => _busy = false);
    }
  }

  Widget _groups(AppLocalizations l10n, {BackupPreview? preview}) =>
      SettingsSection(
        footer: Text(l10n.backupCredentialHint),
        children: [
          _group(
            'backup-settings',
            l10n.backupSettings,
            _settings,
            preview?.hasSettings ?? true,
            (value) => _settings = value,
          ),
          _group(
            'backup-dashboard',
            l10n.backupDashboard,
            _dashboard,
            preview?.hasDashboard ?? true,
            (value) => _dashboard = value,
          ),
          _group(
            'backup-connections',
            l10n.backupConnections,
            _connections,
            preview?.hasConnections ?? true,
            (value) => _connections = value,
          ),
        ],
      );

  Widget _group(
    String key,
    String title,
    bool value,
    bool available,
    ValueChanged<bool> change,
  ) {
    final generation = _generation;
    return CupertinoListTile(
      title: Text(title, maxLines: 2),
      trailing: CupertinoSwitch(
        key: ValueKey(key),
        value: value,
        onChanged: _busy || !available
            ? null
            : (next) {
                if (mounted &&
                    !_busy &&
                    generation == _generation &&
                    _current()) {
                  setState(() {
                    _generation++;
                    change(next);
                  });
                }
              },
      ),
    );
  }

  Widget _password(
    TextEditingController controller,
    String placeholder,
    String key,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    child: CupertinoTextField(
      key: ValueKey(key),
      controller: controller,
      placeholder: placeholder,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      enabled: !_busy,
      padding: const EdgeInsets.all(14),
    ),
  );

  Widget _button(String label, VoidCallback? onPressed, String key) {
    final generation = _generation;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: CupertinoButton.filled(
        key: ValueKey(key),
        onPressed: _busy || onPressed == null
            ? null
            : () {
                if (mounted &&
                    generation == _generation &&
                    _interactive &&
                    (key != 'backup-apply' || _current())) {
                  onPressed();
                }
              },
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Text(
      text,
      style: AppText.footnote.copyWith(
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    ),
  );

  List<Widget> _previewWidgets(AppLocalizations l10n, BackupPreview preview) {
    final generation = _generation;
    return [
      SettingsSection(
        header: Text(l10n.backupPreview),
        children: [
          CupertinoListTile(
            title: Text(l10n.backupCreatedAt),
            additionalInfo: Text(
              DateFormat.yMMMd(Localizations.localeOf(context).toString())
                  .format(preview.createdAt.toLocal()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.backupCountSummary(
                preview.settingCount,
                preview.roomCount,
                preview.tileCount,
                preview.favoriteCount,
              ),
            ),
          ),
          CupertinoListTile(
            title: Text(l10n.backupServices),
            subtitle: Text(
              preview.services.isEmpty
                  ? l10n.backupNoServices
                  : preview.services.map(_serviceName).join(', '),
              maxLines: 4,
            ),
          ),
        ],
      ),
      _groups(l10n, preview: preview),
      SettingsSection(
        header: Text(l10n.backupExistingData),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.backupExistingSummary(
                preview.existingSettingsCount,
                preview.existingServices.length,
              ),
            ),
          ),
          if (preview.existingDashboard)
            CupertinoListTile(
              title: Text(l10n.backupDashboard),
              trailing: const Icon(CupertinoIcons.checkmark),
            ),
          if (preview.existingServices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                preview.existingServices.map(_serviceName).join(', '),
              ),
            ),
        ],
      ),
      _note(l10n.backupConflicts),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: CupertinoSlidingSegmentedControl<BackupConflictPolicy>(
          groupValue: _conflict,
          children: {
            BackupConflictPolicy.keepExisting: Text(l10n.backupKeepExisting),
            BackupConflictPolicy.replaceSelected: Text(
              l10n.backupReplaceSelected,
            ),
          },
          onValueChanged: (value) {
            if (mounted &&
                !_busy &&
                value != null &&
                generation == _generation &&
                _current()) {
              setState(() {
                _generation++;
                _conflict = value;
              });
            }
          },
        ),
      ),
      _note(l10n.backupConflictHint),
      _note(l10n.backupPrivacyPolicyHint),
      if (preview.requiresPrivacyReview)
        _note(l10n.backupPrivacyReviewRequired),
      if (preview.requiresCertificateReview && _connections)
        _note(l10n.backupCertificateReview),
      _button(
        l10n.backupApply,
        _selection.isEmpty ? null : _apply,
        'backup-apply',
      ),
      CupertinoButton(
        onPressed: _busy
            ? null
            : () {
                if (mounted && generation == _generation && _current()) {
                  setState(() {
                    _generation++;
                    _clearSecrets();
                  });
                }
              },
        child: Text(l10n.commonCancel),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(pinLockProvider, (previous, next) {
      final resolved = !next.isLoading && !next.hasError && next.hasValue;
      if (!resolved || _pinResolved && next.value != _pinValue) {
        _generation++;
        _clearSecrets();
      }
      _pinResolved = resolved;
      _pinValue = resolved ? next.value : null;
    });
    final observedPin = ref.watch(pinLockProvider);
    if (!_pinResolved &&
        !observedPin.isLoading &&
        !observedPin.hasError &&
        observedPin.hasValue) {
      _pinResolved = true;
      _pinValue = observedPin.value;
    }
    ref.watch(windowPolicySnapshotProvider);

    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    final freshInstallLocked =
        widget.freshInstall && (!pin.hasValue || pin.value != null);
    return PopScope(
      canPop: !_busy,
      child: AppPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(l10n.backupTitle),
          automaticBackgroundVisibility: false,
        ),
        child: SafeArea(
          child: _suspended || freshInstallLocked
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.backupLocked),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      children: [
                        _note(
                          _restoreMode
                              ? l10n.backupRestoreHint
                              : l10n.backupIntro,
                        ),
                        if (!widget.freshInstall)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            child: CupertinoSlidingSegmentedControl<bool>(
                              groupValue: _restoreMode,
                              children: {
                                false: Text(l10n.backupExport),
                                true: Text(l10n.backupRestore),
                              },
                              onValueChanged: (value) {
                                if (!_busy && value != null) {
                                  setState(() {
                                    _restoreMode = value;
                                    _clearSecrets();
                                    _message = null;
                                    _settings = true;
                                    _dashboard = true;
                                    _connections = false;
                                  });
                                }
                              },
                            ),
                          ),
                        if (!_restoreMode) ...[
                          _groups(l10n),
                          _password(
                            _passphrase,
                            l10n.backupPassphrase,
                            'backup-passphrase',
                          ),
                          _password(
                            _confirmation,
                            l10n.backupConfirmPassphrase,
                            'backup-confirm-passphrase',
                          ),
                          _note(l10n.backupPassphraseHint),
                          _button(l10n.backupExport, _export, 'backup-export'),
                        ] else ...[
                          _button(
                            _file == null
                                ? l10n.backupChooseFile
                                : l10n.backupSelectAnother,
                            _chooseFile,
                            'backup-pick',
                          ),
                          if (_file != null && _preview == null) ...[
                            _note(l10n.backupFileSelected),
                            _password(
                              _restorePassphrase,
                              l10n.backupPassphrase,
                              'backup-restore-passphrase',
                            ),
                            _button(
                              l10n.backupDecrypt,
                              _decrypt,
                              'backup-decrypt',
                            ),
                          ],
                          if (_preview case final preview?)
                            ..._previewWidgets(l10n, preview),
                        ],
                        if (_busy)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CupertinoActivityIndicator()),
                          ),
                        if (_message != null)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              _message!,
                              key: const ValueKey('backup-message'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _isError
                                    ? CupertinoColors.systemRed.resolveFrom(
                                        context,
                                      )
                                    : CupertinoColors.label.resolveFrom(
                                        context,
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
}

String _serviceName(String id) =>
    const {
      'ha': 'Home Assistant',
      'jellyfin': 'Jellyfin',
      'jellyseerr': 'Jellyseerr',
      'sonarr': 'Sonarr',
      'radarr': 'Radarr',
      'lidarr': 'Lidarr',
      'readarr': 'Readarr',
      'bazarr': 'Bazarr',
      'prowlarr': 'Prowlarr',
      'qbittorrent': 'qBittorrent',
      'proxmox': 'Proxmox',
      'keenetic': 'Keenetic',
    }[id] ??
    id;

/// Cupertino's large-text action content omits the regular button semantics.
/// Keep explicit semantics and keyboard activation across both sizing modes.
class _RestoreDialogAction extends StatefulWidget {
  const _RestoreDialogAction({
    required this.onPressed,
    required this.label,
    this.isDestructiveAction = false,
  });
  final VoidCallback onPressed;
  final String label;
  final bool isDestructiveAction;
  @override
  State<_RestoreDialogAction> createState() => _RestoreDialogActionState();
}

class _RestoreDialogActionState extends State<_RestoreDialogAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => CupertinoDialogAction(
    onPressed: widget.onPressed,
    isDestructiveAction: widget.isDestructiveAction,
    child: FocusableActionDetector(
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: true,
        label: widget.label,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(
              width: 2,
              color: _focused
                  ? CupertinoTheme.of(context).primaryColor
                  : CupertinoColors.transparent,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(widget.label),
        ),
      ),
    ),
  );
}
