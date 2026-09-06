import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../client_updates/presentation/client_updates_screen.dart';
import '../../home_scope/presentation/home_source_screen.dart';
import '../../home_resources/presentation/home_resource_admin_screen.dart';
import '../../server/presentation/server_connection_screen.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/settings_providers.dart';
import 'settings_split_screen.dart';
import 'settings_file_dialog.dart';

enum SettingsGateDestination {
  settings,
  clientUpdates,
  serverAccount,
  homeSource,
  homeResources,
}

/// Gates access to [SettingsSplitScreen] behind a PIN, if one has been set —
/// protects the connection config and admin panel from casual tampering on
/// a shared wall-mounted tablet. No PIN set (the default) means unlocked.
class SettingsGateScreen extends ConsumerStatefulWidget {
  const SettingsGateScreen({
    super.key,
    this.initialDestination = SettingsGateDestination.settings,
  });

  final SettingsGateDestination initialDestination;

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
  GlobalKey<NavigatorState> _settingsNavigator = GlobalKey<NavigatorState>();
  Route<bool>? _reauthRoute;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;
  bool get _interactive => _interaction?.active ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next;
    _interactionEpoch = next?.epoch ?? 0;
    next?.addListener(_interactionChanged);
  }

  void _interactionChanged() {
    if (!mounted) return;
    final epoch = _interaction?.epoch ?? 0;
    if (epoch != _interactionEpoch) {
      _interactionEpoch = epoch;
      _lockSettings();
    }
  }

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
    final reauth = _reauthRoute;
    _reauthRoute = null;
    if (reauth?.isActive == true) reauth!.navigator?.removeRoute(reauth);
    setState(() {
      _unlocked = false;
      _checking = false;
      _error = null;
      if (!_fileDialogActive) {
        _settingsOpened = false;
        _settingsNavigator = GlobalKey<NavigatorState>();
      }
    });
    // A native picker may background the app. Its already-open route can
    // retain ciphertext, but cannot continue until the gate reauthenticates.
    if (_fileDialogActive) return;
    // The nested Navigator owns settings pages and their dialogs. Resetting its
    // key closes only these routes, preserving unrelated root overlays.
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pinLockProvider, (previous, next) {
      if (widget.initialDestination == SettingsGateDestination.homeResources &&
          (next.isLoading || next.hasError)) {
        _lockSettings();
        return;
      }
      if (previous?.hasValue == true &&
          next.hasValue &&
          (next.value != null ||
              widget.initialDestination ==
                  SettingsGateDestination.homeResources) &&
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
        final resourceGeneration = _generation;
        final archiveNavigator = _settingsNavigator;
        if (unlocked) _settingsOpened = true;
        return Stack(
          children: [
            if (unlocked || (_fileDialogActive && _settingsOpened))
              Offstage(
                offstage: !unlocked,
                child: TickerMode(
                  enabled: unlocked,
                  child: NavigatorPopHandler(
                    enabled: unlocked,
                    onPopWithResult: (_) =>
                        _settingsNavigator.currentState?.maybePop(),
                    child: Navigator(
                      key: _settingsNavigator,
                      onGenerateRoute: (_) => CupertinoPageRoute<void>(
                        builder: (_) =>
                            widget.initialDestination ==
                                SettingsGateDestination.serverAccount
                            ? ServerConnectionScreen(
                                onExit: Navigator.of(context).canPop()
                                    ? _exit
                                    : null,
                              )
                            : widget.initialDestination ==
                                  SettingsGateDestination.homeResources
                            ? HomeResourceAdminScreen(
                                gateCurrent: () {
                                  if (!mounted ||
                                      !_interactive ||
                                      resourceGeneration != _generation ||
                                      ModalRoute.of(context)?.isCurrent !=
                                          true) {
                                    return false;
                                  }
                                  final currentPin = ref.read(pinLockProvider);
                                  return !currentPin.isLoading &&
                                      !currentPin.hasError &&
                                      currentPin.hasValue &&
                                      currentPin.value == pin &&
                                      (pin == null || _unlocked);
                                },
                                onExit: Navigator.of(context).canPop()
                                    ? _exit
                                    : null,
                              )
                            : widget.initialDestination ==
                                  SettingsGateDestination.homeSource
                            ? HomeSourceScreen(
                                runFileDialog: _runFileDialog,
                                archiveGateCurrent: () {
                                  if (!mounted ||
                                      !_interactive ||
                                      !identical(
                                        archiveNavigator,
                                        _settingsNavigator,
                                      ) ||
                                      ModalRoute.of(context)?.isCurrent !=
                                          true) {
                                    return false;
                                  }
                                  final value = ref.read(pinLockProvider);
                                  return !value.isLoading &&
                                      !value.hasError &&
                                      value.hasValue &&
                                      (value.value == null || _unlocked);
                                },
                                onExit: Navigator.of(context).canPop()
                                    ? _exit
                                    : null,
                              )
                            : widget.initialDestination ==
                                  SettingsGateDestination.clientUpdates
                            ? ClientUpdatesScreen(
                                onExit: Navigator.of(context).canPop()
                                    ? _exit
                                    : null,
                              )
                            : SettingsSplitScreen(
                                backupGateCurrent: () {
                                  if (!mounted ||
                                      !_interactive ||
                                      resourceGeneration != _generation ||
                                      ModalRoute.of(context)?.isCurrent !=
                                          true) {
                                    return false;
                                  }
                                  final value = ref.read(pinLockProvider);
                                  return !value.isLoading &&
                                      !value.hasError &&
                                      value.hasValue &&
                                      (value.value == null || _unlocked);
                                },
                                runFileDialog: _runFileDialog,
                                onExit: Navigator.of(context).canPop()
                                    ? () {
                                        if (mounted &&
                                            _interactive &&
                                            ModalRoute.of(context)?.isCurrent ==
                                                true) {
                                          Navigator.of(context).maybePop();
                                        }
                                      }
                                    : null,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            if (!unlocked) Positioned.fill(child: _buildPinEntry(context)),
          ],
        );
      },
    );
  }

  void _exit() {
    if (mounted && _interactive && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).maybePop();
    }
  }

  Future<T?> _runFileDialog<T>(Future<T?> Function() operation) async {
    if (_fileDialogActive) return null;
    final generation = _generation;
    final store = ref.read(pinLockStoreProvider);
    final pin = await store.read();
    if (!mounted ||
        !_interactive ||
        generation != _generation ||
        (pin != null && !_unlocked)) {
      return null;
    }
    _fileDialogActive = true;
    try {
      final result = await operation();
      if (!mounted || !_interactive || result == null) return null;
      if (!_unlocked && await store.read() != null) {
        if (!mounted) return null;
        final epoch = _generation;
        final accepted = await reauthenticateSettingsFileDialog(
          context,
          store,
          onRoute: (route) => _reauthRoute = route,
        );
        _reauthRoute = null;
        if (!mounted || !_interactive || epoch != _generation || !accepted) {
          return null;
        }
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
    if (!mounted || !_interactive || _checking) return;
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
