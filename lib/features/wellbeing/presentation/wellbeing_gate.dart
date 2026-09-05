import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../auth/providers/auth_providers.dart';
import '../../health/data/health_configuration.dart';
import '../../settings/presentation/settings_gate_screen.dart';
import '../../settings/providers/settings_providers.dart';
import '../domain/wellbeing_models.dart';
import '../data/wellbeing_view_privacy.dart';
import '../providers/wellbeing_providers.dart';
import 'wellbeing_screen.dart';

/// Private readings require a fresh local PIN session, including after idle.
class WellbeingGate extends ConsumerStatefulWidget {
  const WellbeingGate({super.key});
  @override
  ConsumerState<WellbeingGate> createState() => _WellbeingGateState();
}

class _WellbeingGateState extends ConsumerState<WellbeingGate>
    with WidgetsBindingObserver {
  final _pin = TextEditingController();
  AppInteractionController? _interaction;
  WellbeingAccessSession? _access;
  WellbeingViewPrivacy? _privacy;
  Object? _privacyOwner;
  GlobalKey<NavigatorState> _privateNavigator = GlobalKey<NavigatorState>();
  int _generation = 0;
  bool _checking = false;
  bool _routeWasCurrent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeCurrent = ModalRoute.isCurrentOf(context) == true;
    if ((_routeWasCurrent && !routeCurrent) ||
        (!TickerMode.valuesOf(context).enabled &&
            (_access != null || _checking))) {
      _lock();
    }
    _routeWasCurrent = routeCurrent;
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = next;
      next?.addListener(_interactionChanged);
      if (_access != null) _lock();
    }
  }

  void _interactionChanged() {
    if (_interaction?.active == false) _lock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _lock();
  }

  void _lock() {
    _generation++;
    _releasePrivateView();
    _pin.clear();
    if (!mounted) return;
    setState(() {
      _access = null;
      _checking = false;
      _error = null;
    });
  }

  void _releasePrivateView() {
    final owner = _privacyOwner;
    final privacy = _privacy;
    _privacyOwner = null;
    if (owner == null || privacy == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      privacy.release(owner).catchError((Object _) {});
    });
  }

  bool _current(int generation) =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      generation == _generation &&
      _interaction?.active != false &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> _unlock() async {
    final generation = _generation;
    if (_checking || !_current(generation)) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await ref.read(pinLockStoreProvider).verify(_pin.text);
      if (!mounted || !_current(generation)) return;
      _pin.clear();
      if (result.accepted && ref.read(pinLockProvider).value != null) {
        final owner = Object();
        final privacy = ref.read(wellbeingViewPrivacyProvider);
        await privacy.acquire(owner, isCurrent: () => _current(generation));
        if (!_current(generation)) {
          await privacy.release(owner);
          return;
        }
        _privacy = privacy;
        _privacyOwner = owner;
        _privateNavigator = GlobalKey<NavigatorState>();
      }
      if (!mounted || !_current(generation)) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        if (result.accepted && ref.read(pinLockProvider).value != null) {
          _access = WellbeingAccessSession(
            isCurrent: () => _current(generation),
          );
        } else {
          _error = result.retryAfter > Duration.zero
              ? l10n.settingsGateRetryAfter(
                  (result.retryAfter.inMilliseconds / 1000).ceil(),
                )
              : l10n.settingsGateIncorrectPin;
        }
      });
    } catch (_) {
      if (_current(generation)) {
        setState(
          () => _error = AppLocalizations.of(context).settingsGateStorageError,
        );
      }
    } finally {
      if (_current(generation)) setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _releasePrivateView();
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading || next.hasError || previous?.value != next.value) {
        _lock();
      }
    });
    ref.listen(connectionConfigProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          !sameHealthConfiguration(previous?.value, next.value)) {
        _lock();
      }
    });
    if (!pin.isLoading &&
        !pin.hasError &&
        pin.value != null &&
        _access != null) {
      return ProviderScope(
        key: ValueKey(_access),
        overrides: [wellbeingAccessProvider.overrideWithValue(_access)],
        child: NavigatorPopHandler(
          onPopWithResult: (_) => _privateNavigator.currentState?.maybePop(),
          child: Navigator(
            key: _privateNavigator,
            onGenerateRoute: (_) => CupertinoPageRoute<void>(
              builder: (_) => WellbeingScreen(
                onLock: _lock,
                onExit: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ),
      );
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.wellbeingTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.heart_circle, size: 48),
                  const SizedBox(height: 20),
                  if (pin.isLoading)
                    const CupertinoActivityIndicator()
                  else if (pin.hasError)
                    Text(l10n.settingsGateStorageError)
                  else if (pin.value == null) ...[
                    Text(l10n.wellbeingPinRequired),
                    CupertinoButton(
                      onPressed: () => Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          builder: (_) => const SettingsGateScreen(),
                        ),
                      ),
                      child: Text(l10n.wellbeingConfigurePin),
                    ),
                  ] else ...[
                    Text(l10n.wellbeingPrivacy),
                    const SizedBox(height: 20),
                    CupertinoTextField(
                      key: const ValueKey('wellbeing-pin'),
                      controller: _pin,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.number,
                      enabled: !_checking,
                      placeholder: l10n.settingsGatePinPlaceholder,
                      onSubmitted: (_) => _unlock(),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!),
                      ),
                    CupertinoButton.filled(
                      onPressed: _checking ? null : _unlock,
                      child: Text(l10n.settingsGateUnlockButton),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
