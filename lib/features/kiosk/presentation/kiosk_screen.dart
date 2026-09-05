import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../domain/kiosk_models.dart';
import '../data/kiosk_controller.dart';
import '../providers/kiosk_providers.dart';

String _actionLabel(AppLocalizations l, KioskAction a) => switch (a) {
  KioskAction.allowApp => l.kioskAllow,
  KioskAction.removeApp => l.kioskRemove,
  KioskAction.restorePowerMenu => l.kioskRestorePower,
  KioskAction.enter => l.kioskEnter,
  KioskAction.exit => l.kioskExit,
};
String _failureLabel(AppLocalizations l, Object error) => switch (error) {
  KioskException(failure: KioskFailure.unsupported) => l.kioskUnsupported,
  KioskException(failure: KioskFailure.denied) => l.kioskDenied,
  KioskException(failure: KioskFailure.expired) => l.kioskExpired,
  KioskException(failure: KioskFailure.pinRequired) => l.kioskPinRequired,
  KioskException(failure: KioskFailure.wrongPin) => l.settingsGateIncorrectPin,
  KioskException(failure: KioskFailure.rateLimited, retryAfter: final delay) =>
    l.settingsGateRetryAfter((delay.inMilliseconds / 1000).ceil()),
  _ => l.kioskUnavailable,
};

class KioskScreen extends ConsumerStatefulWidget {
  const KioskScreen({super.key});
  @override
  ConsumerState<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends MediaSessionState<KioskScreen> {
  late final KioskController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(kioskControllerProvider);
  }

  KioskSnapshot? _snapshot;
  KioskReceipt? _receipt;
  String? _error;
  bool _loading = false, _pending = false, _mustRefresh = false, _ticker = true;
  Route<String>? _pinRoute;
  TextEditingController? _pin;
  int _read = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final was = _ticker;
    _ticker = TickerMode.valuesOf(context).enabled;
    if (!_ticker && was) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    if (_ticker && _snapshot == null && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _current(sessionGeneration)) _refresh();
      });
    }
  }

  bool _current(int epoch, {bool ownModal = false}) =>
      sessionCurrent(epoch) &&
      _ticker &&
      (ModalRoute.of(context)?.isCurrent == true ||
          (ownModal && _pinRoute?.isCurrent == true));
  @override
  void clearPendingInteraction() {
    _read++;
    _snapshot = null;
    _receipt = null;
    _error = null;
    _loading = false;
    _controller.invalidate();
    _erasePin();
    _retirePinRoute();
  }

  void _erasePin() {
    final pin = _pin;
    if (pin == null) return;
    void clear() {
      if (identical(_pin, pin)) pin.clear();
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => clear());
    } else {
      clear();
    }
  }

  void _retirePinRoute() {
    final route = _pinRoute;
    _pinRoute = null;
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

  @override
  void resumeMediaSession() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    final epoch = sessionGeneration;
    if (_loading || _pending || !_current(epoch)) return;
    final read = ++_read;
    setState(() {
      _loading = true;
      _snapshot = null;
      _error = null;
      _receipt = null;
    });
    final controller = _controller;
    try {
      final snapshot = await controller.snapshot();
      if (!_current(epoch) || read != _read) return;
      setState(() {
        _snapshot = snapshot;
        _mustRefresh = false;
      });
    } catch (error) {
      if (_current(epoch) && read == _read) {
        setState(
          () => _error = _failureLabel(AppLocalizations.of(context), error),
        );
      }
    } finally {
      if (mounted && read == _read) setState(() => _loading = false);
    }
  }

  Future<void> _act(KioskAction action) async {
    final epoch = sessionGeneration;
    if (_pending ||
        _loading ||
        _mustRefresh ||
        !_current(epoch) ||
        _snapshot?.actions.contains(action) != true) {
      return;
    }
    final controller = _controller;
    setState(() {
      _pending = true;
      _error = null;
      _receipt = null;
    });
    try {
      final intent = await controller.prepare(
        action,
        isCurrent: () => _current(epoch),
      );
      if (!mounted || !_current(epoch)) {
        controller.invalidate();
        return;
      }
      final pin = TextEditingController();
      _pin = pin;
      final l = AppLocalizations.of(context);
      final route = CupertinoDialogRoute<String>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(_actionLabel(l, action)),
          content: Column(
            children: [
              Text(l.kioskPinHint),
              if (action == KioskAction.removeApp ||
                  action == KioskAction.allowApp)
                Text(l.kioskAllowHint),
              const SizedBox(height: 12),
              CupertinoTextField(
                key: const ValueKey('kiosk-pin'),
                controller: pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(12),
                ],
                placeholder: l.settingsPinPlaceholder,
                autocorrect: false,
                enableSuggestions: false,
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => _finishPin(dialog, epoch, null),
              child: Text(l.commonCancel),
            ),
            CupertinoDialogAction(
              key: const ValueKey('kiosk-confirm'),
              isDestructiveAction: action == KioskAction.removeApp,
              onPressed: () => _finishPin(dialog, epoch, pin.text),
              child: Text(_actionLabel(l, action)),
            ),
          ],
        ),
      );
      setState(() => _pinRoute = route);
      if (!mounted) {
        controller.invalidate();
        pin.dispose();
        return;
      }
      final entered = await Navigator.of(context).push(route);
      await route.completed;
      if (identical(_pinRoute, route)) _pinRoute = null;
      if (identical(_pin, pin)) _pin = null;
      pin.clear();
      pin.dispose();
      if (entered == null || !_current(epoch)) {
        controller.invalidate();
        return;
      }
      final receipt = await controller.execute(
        intent,
        entered,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      setState(() {
        _receipt = receipt;
        _snapshot = receipt.snapshot;
        _mustRefresh = receipt.outcome != KioskOutcome.observed;
      });
    } catch (error) {
      controller.invalidate();
      if (_current(epoch)) {
        setState(
          () => _error = _failureLabel(AppLocalizations.of(context), error),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  void _finishPin(BuildContext dialog, int epoch, String? value) {
    if (_current(epoch, ownModal: true) &&
        dialog.mounted &&
        ModalRoute.of(dialog)?.isCurrent == true) {
      Navigator.pop(dialog, value);
    }
  }

  @override
  void dispose() {
    _read++;
    _erasePin();
    _retirePinRoute();
    _controller.invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(kioskControllerProvider);
    final l = AppLocalizations.of(context), snapshot = _snapshot;
    final active =
        _current(sessionGeneration) && !_pending && !_loading && !_mustRefresh;
    String truth(bool? value) =>
        value == null ? l.commonUnknown : (value ? l.commonYes : l.commonNo);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l.kioskTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Text(l.kioskHint, style: AppText.body),
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CupertinoActivityIndicator()),
                    ),
                  if (snapshot != null && !snapshot.supported)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l.kioskUnsupported),
                    ),
                  if (snapshot?.supported == true) ...[
                    SettingsSection(
                      header: Text(l.kioskState),
                      footer: Text(l.kioskExternalHint),
                      children: [
                        _row(l.kioskState, switch (snapshot!.lockState) {
                          KioskLockState.none => l.kioskNone,
                          KioskLockState.pinned => l.kioskPinned,
                          KioskLockState.locked => l.kioskLocked,
                          KioskLockState.unknown => l.commonUnknown,
                        }),
                        _row(l.kioskDeviceOwner, truth(snapshot.deviceOwner)),
                        _row(l.kioskPermitted, truth(snapshot.permitted)),
                        _row(
                          l.kioskPowerMenu,
                          truth(snapshot.powerMenuAllowed),
                        ),
                      ],
                    ),
                    SettingsSection(
                      footer: Text(l.kioskWindowHint),
                      children: [
                        for (final action in [
                          KioskAction.exit,
                          KioskAction.enter,
                        ])
                          _actionButton(
                            l,
                            action,
                            active && snapshot.actions.contains(action),
                          ),
                      ],
                    ),
                    SettingsSection(
                      footer: Text(l.kioskAllowHint),
                      children: [
                        for (final action in [
                          KioskAction.allowApp,
                          KioskAction.removeApp,
                          KioskAction.restorePowerMenu,
                        ])
                          _actionButton(
                            l,
                            action,
                            active && snapshot.actions.contains(action),
                          ),
                      ],
                    ),
                  ],
                  if (_pending && _pinRoute == null)
                    const Center(child: CupertinoActivityIndicator()),
                  if (_receipt != null)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(switch (_receipt!.outcome) {
                        KioskOutcome.observed => l.kioskObserved,
                        KioskOutcome.accepted => l.kioskAccepted,
                        KioskOutcome.unknown => l.kioskUnknown,
                      }, key: const ValueKey('kiosk-receipt')),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                      ),
                    ),
                  CupertinoButton(
                    key: const ValueKey('kiosk-refresh'),
                    onPressed:
                        !_pending && !_loading && _current(sessionGeneration)
                        ? _refresh
                        : null,
                    child: Text(l.commonRefresh),
                  ),
                  SettingsSection(
                    header: Text(l.kioskRecovery),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l.kioskRecoveryHint, style: AppText.body),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton(AppLocalizations l, KioskAction action, bool enabled) =>
      SizedBox(
        width: double.infinity,
        child: CupertinoButton(
          key: ValueKey('kiosk-${action.name}'),
          onPressed: enabled ? () => _act(action) : null,
          child: Text(_actionLabel(l, action), textAlign: TextAlign.center),
        ),
      );

  Widget _row(String name, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(name, style: AppText.footnote),
        Text(value, style: AppText.headline),
      ],
    ),
  );
}
