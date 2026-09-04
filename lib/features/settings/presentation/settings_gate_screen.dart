import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_page_scaffold.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/settings_providers.dart';
import 'settings_split_screen.dart';
import 'settings_file_dialog.dart';

/// Gates access to [SettingsSplitScreen] behind a PIN, if one has been set —
/// protects the connection config and admin panel from casual tampering on
/// a shared wall-mounted tablet. No PIN set (the default) means unlocked.
class SettingsGateScreen extends ConsumerStatefulWidget {
  const SettingsGateScreen({super.key});

  @override
  ConsumerState<SettingsGateScreen> createState() => _SettingsGateScreenState();
}

class _SettingsGateScreenState extends ConsumerState<SettingsGateScreen>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  bool _unlocked = false;
  bool _checking = false;
  int _generation = 0;
  String? _error;
  bool _fileDialogActive = false;
  bool _settingsOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    _lockSettings();
  }

  void _lockSettings() {
    // Invalidate a pending verification as well as an already unlocked session.
    _generation++;
    _controller.clear();
    if (!_unlocked && !_checking && ref.read(pinLockProvider).value == null) {
      return;
    }
    setState(() {
      _unlocked = false;
      _checking = false;
      _error = null;
    });
    // A native picker may background the app. Its already-open route can
    // retain ciphertext, but cannot continue until the gate reauthenticates.
    if (_fileDialogActive) return;
    _settingsOpened = false;
    // Phone settings push routes above this gate; remove those routes as well.
    // Tablet detail routes disappear with the SettingsSplitScreen subtree.
    final gate = ModalRoute.of(context);
    if (gate != null) Navigator.of(context).popUntil((route) => route == gate);
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pinLockProvider, (previous, next) {
      if (previous?.hasValue == true &&
          next.hasValue &&
          next.value != null &&
          previous?.value != next.value) {
        // First PIN creation also closes a phone pane pushed while no PIN was
        // configured. A locked gate underneath that pane is not sufficient.
        _lockSettings();
      }
    });
    final pinAsync = ref.watch(pinLockProvider);

    return pinAsync.when(
      loading: () => const AppPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => AppPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).settingsGateStorageError),
        ),
      ),
      data: (pin) {
        final unlocked = pin == null || _unlocked;
        if (unlocked) _settingsOpened = true;
        return Stack(
          children: [
            if (unlocked || (_fileDialogActive && _settingsOpened))
              Offstage(
                offstage: !unlocked,
                child: TickerMode(
                  enabled: unlocked,
                  child: SettingsSplitScreen(runFileDialog: _runFileDialog),
                ),
              ),
            if (!unlocked) Positioned.fill(child: _buildPinEntry(context)),
          ],
        );
      },
    );
  }

  Future<T?> _runFileDialog<T>(Future<T?> Function() operation) async {
    if (_fileDialogActive) return null;
    final store = ref.read(pinLockStoreProvider);
    final pin = await store.read();
    if (!mounted || (pin != null && !_unlocked)) return null;
    _fileDialogActive = true;
    try {
      final result = await operation();
      if (!mounted || result == null) return null;
      if (!_unlocked && await store.read() != null) {
        if (!mounted) return null;
        final accepted = await reauthenticateSettingsFileDialog(context, store);
        if (!mounted || !accepted) return null;
        setState(() => _unlocked = true);
      }
      return result;
    } finally {
      _fileDialogActive = false;
      if (mounted && !_unlocked && ref.read(pinLockProvider).value != null) {
        _lockSettings();
      }
    }
  }

  Widget _buildPinEntry(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        // Deliberately a middle title even though Settings itself uses a
        // large one: this is a lock screen, not the destination.
        middle: Text(l10n.settingsScreenTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.lock_fill,
                    size: 40,
                    color: CupertinoTheme.of(context).primaryColor,
                  ),
                  const SizedBox(height: 16),
                  CupertinoTextField(
                    controller: _controller,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    autofocus: true,
                    placeholder: l10n.settingsGatePinPlaceholder,
                    enabled: !_checking,
                    enableSuggestions: false,
                    autocorrect: false,
                    onSubmitted: (_) => _submit(l10n),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  CupertinoButton.filled(
                    onPressed: _checking ? null : () => _submit(l10n),
                    child: Text(l10n.settingsGateUnlockButton),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(AppLocalizations l10n) async {
    if (_checking) return;
    final generation = _generation;
    final candidate = _controller.text;
    setState(() => _checking = true);
    try {
      final result = await ref.read(pinLockStoreProvider).verify(candidate);
      if (!mounted || generation != _generation) return;
      _controller.clear();
      setState(() {
        _unlocked = result.accepted;
        _error = result.accepted
            ? null
            : result.retryAfter > Duration.zero
            ? l10n.settingsGateRetryAfter(
                (result.retryAfter.inMilliseconds / 1000).ceil(),
              )
            : l10n.settingsGateIncorrectPin;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = l10n.settingsGateStorageError);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _checking = false);
      }
    }
  }
}
