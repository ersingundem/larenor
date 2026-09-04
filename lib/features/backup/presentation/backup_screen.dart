import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Configuration migration only: every mutation is to this device's storage.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({
    super.key,
    this.freshInstall = false,
    this.runFileDialog,
  });

  final bool freshInstall;
  final SettingsFileDialogRunner? runFileDialog;

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen>
    with WidgetsBindingObserver {
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  final _restorePassphrase = TextEditingController();
  bool _restoreMode = false;
  bool _settings = true;
  bool _dashboard = true;
  bool _connections = false;
  bool _busy = false;
  bool _fileDialog = false;
  bool _suspended = false;
  int _generation = 0;
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
    _restoreMode = widget.freshInstall;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _generation++;
      _clearSecrets();
      setState(() => _suspended = true);
    } else if (state == AppLifecycleState.resumed && !_fileDialog) {
      setState(() => _suspended = false);
    }
  }

  void _clearSecrets() {
    _passphrase.clear();
    _confirmation.clear();
    _restorePassphrase.clear();
    _snapshot = null;
    _preview = null;
  }

  @override
  void dispose() {
    _generation++;
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
    if (!widget.freshInstall) return true;
    final pin = await ref.read(pinLockStoreProvider).read();
    if (!mounted) return false;
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
      if (mounted) setState(() => _suspended = false);
    }
  }

  Future<void> _export() async {
    if (_busy) return;
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
    if (_busy) return;
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
    if (_busy || _file == null) return;
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
    if (_busy || _snapshot == null || _selection.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final generation = _generation;
    var handedOff = false;
    setState(() => _busy = true);
    try {
      if (!await _authorized() || !mounted || generation != _generation) return;
      final accepted =
          await showCupertinoDialog<bool>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: Text(l10n.backupApplyTitle),
              content: Text(l10n.backupApplyMessage),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l10n.commonCancel),
                ),
                CupertinoDialogAction(
                  isDestructiveAction:
                      _conflict == BackupConflictPolicy.replaceSelected,
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l10n.backupApply),
                ),
              ],
            ),
          ) ??
          false;
      if (!mounted ||
          generation != _generation ||
          !accepted ||
          _snapshot == null) {
        return;
      }
      // A PIN could have been installed while the confirmation was open.
      if (!await _authorized() || !mounted || generation != _generation) return;
      final snapshot = _snapshot!;
      final selection = _selection;
      final conflict = _conflict;
      final repository = ref.read(backupRepositoryProvider);
      final restore = ref.read(backupRestoreHandlerProvider);
      handedOff = true;
      // This disposes this route and all old providers before persistence.
      // Never use ref/context/state after invoking the boundary.
      await restore(
        context,
        () => repository.restore(snapshot, selection, conflictPolicy: conflict),
        l10n,
      );
    } catch (_) {
      if (!handedOff && mounted && generation == _generation) {
        _showMessage(l10n.backupFailed, error: true);
      }
    } finally {
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
  ) => CupertinoListTile(
    title: Text(title, maxLines: 2),
    trailing: CupertinoSwitch(
      key: ValueKey(key),
      value: value,
      onChanged: _busy || !available
          ? null
          : (next) => setState(() => change(next)),
    ),
  );

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

  Widget _button(String label, VoidCallback? onPressed, String key) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: CupertinoButton.filled(
      key: ValueKey(key),
      onPressed: _busy ? null : onPressed,
      child: Text(label, textAlign: TextAlign.center),
    ),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Text(
      text,
      style: AppText.footnote.copyWith(
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    ),
  );

  List<Widget> _previewWidgets(
    AppLocalizations l10n,
    BackupPreview preview,
  ) => [
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
            child: Text(preview.existingServices.map(_serviceName).join(', ')),
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
          if (!_busy && value != null) setState(() => _conflict = value);
        },
      ),
    ),
    _note(l10n.backupConflictHint),
    if (preview.requiresCertificateReview && _connections)
      _note(l10n.backupCertificateReview),
    _button(
      l10n.backupApply,
      _selection.isEmpty ? null : _apply,
      'backup-apply',
    ),
    CupertinoButton(
      onPressed: _busy ? null : () => setState(_clearSecrets),
      child: Text(l10n.commonCancel),
    ),
  ];

  @override
  Widget build(BuildContext context) {
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
