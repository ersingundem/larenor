import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/kiosk_sensor_controller.dart';
import '../domain/kiosk_sensor_models.dart';
import '../providers/kiosk_sensor_providers.dart';

final class KioskSensorScreen extends ConsumerStatefulWidget {
  const KioskSensorScreen({super.key});

  @override
  ConsumerState<KioskSensorScreen> createState() => _KioskSensorScreenState();
}

final class _KioskSensorScreenState extends ConsumerState<KioskSensorScreen>
    with WidgetsBindingObserver {
  late KioskSensorController _controller;
  KioskSensorSnapshot? _snapshot;
  KioskSensorSensitivity _sensitivity = KioskSensorSensitivity.medium;
  Timer? _poller;
  String? _error;
  bool _pending = false;
  bool _foreground = true;
  bool _nativeFocused = true;
  bool _routeVisible = true;
  AppInteractionController? _interaction;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _controller = ref.read(kioskSensorControllerProvider);
    ref.listenManual(kioskSensorControllerProvider, (previous, next) {
      if (previous == null || identical(previous, next) || !mounted) return;
      unawaited(_retire());
      setState(() => _controller = next);
    });
  }

  bool _current(int epoch) =>
      mounted &&
      epoch == _epoch &&
      _foreground &&
      _nativeFocused &&
      (_interaction?.active ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (visible != _routeVisible) {
      _routeVisible = visible;
      if (!visible) unawaited(_retire());
    }
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = next?..addListener(_interactionChanged);
      if (_interaction?.active == false) unawaited(_retire());
    }
  }

  void _interactionChanged() {
    if (_interaction?.active == false) unawaited(_retire());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      unawaited(_retire());
    } else if (mounted) {
      setState(() => _error = null);
    }
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != View.of(context).viewId) return;
    final focused = event.state == ViewFocusState.focused;
    if (_nativeFocused == focused) return;
    _nativeFocused = focused;
    if (!focused) {
      unawaited(_retire());
    } else {
      setState(() => _error = null);
    }
  }

  Future<void> _start() async {
    if (_pending) return;
    final epoch = ++_epoch;
    if (!_current(epoch)) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      final value = await _controller.start(intervalMillis: 1000);
      if (!_current(epoch)) {
        await _controller.retire();
        return;
      }
      setState(() => _snapshot = value);
      _poller?.cancel();
      _poller = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_refresh(epoch)),
      );
    } catch (error) {
      if (_current(epoch)) {
        setState(() {
          _snapshot = null;
          _error = _failure(error);
        });
      }
    } finally {
      if (_current(epoch)) setState(() => _pending = false);
    }
  }

  Future<void> _refresh(int epoch) async {
    if (!_current(epoch) || _pending || !_controller.active) return;
    try {
      final value = await _controller.refresh();
      if (_current(epoch)) setState(() => _snapshot = value);
    } catch (error) {
      if (_current(epoch)) {
        await _retire();
        if (mounted) setState(() => _error = _failure(error));
      }
    }
  }

  Future<void> _stop() async {
    final epoch = _epoch;
    if (!_current(epoch) || _pending) return;
    setState(() => _pending = true);
    try {
      await _controller.stop();
      if (_current(epoch)) setState(() => _snapshot = null);
    } catch (error) {
      if (_current(epoch)) {
        setState(() {
          _snapshot = null;
          _error = _failure(error);
        });
      }
    } finally {
      _poller?.cancel();
      if (_current(epoch)) setState(() => _pending = false);
    }
  }

  Future<void> _retire() async {
    _epoch++;
    _poller?.cancel();
    _poller = null;
    if (mounted) {
      setState(() {
        _snapshot = null;
        _pending = false;
      });
    } else {
      _snapshot = null;
      _pending = false;
    }
    await _controller.retire();
  }

  String _failure(Object error) {
    final l = AppLocalizations.of(context);
    return switch (error) {
      KioskSensorException(failure: KioskSensorFailure.unsupported) =>
        l.kioskUnsupported,
      KioskSensorException(failure: KioskSensorFailure.denied) => l.kioskDenied,
      _ => l.kioskSensorsUnavailable,
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_interactionChanged);
    _epoch++;
    _poller?.cancel();
    unawaited(_controller.retire());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(kioskSensorControllerProvider);
    final l = AppLocalizations.of(context);
    final snapshot = _snapshot;
    final action = !_foreground || !_nativeFocused || _pending
        ? null
        : snapshot == null
        ? _start
        : _stop;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l.kioskSensorsTitle)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: Text(l.kioskSensorsHint, style: AppText.body),
                  ),
                  SettingsSection(
                    header: Semantics(
                      header: true,
                      child: Text(l.kioskSensorsSensitivity),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child:
                            CupertinoSlidingSegmentedControl<
                              KioskSensorSensitivity
                            >(
                              groupValue: _sensitivity,
                              children: {
                                KioskSensorSensitivity.low: _segment(
                                  l.kioskSensorsLow,
                                ),
                                KioskSensorSensitivity.medium: _segment(
                                  l.kioskSensorsMedium,
                                ),
                                KioskSensorSensitivity.high: _segment(
                                  l.kioskSensorsHigh,
                                ),
                              },
                              onValueChanged: (value) {
                                if (snapshot == null &&
                                    value != null &&
                                    _current(_epoch)) {
                                  setState(() => _sensitivity = value);
                                }
                              },
                            ),
                      ),
                    ],
                  ),
                  SettingsSection(
                    header: Semantics(
                      header: true,
                      liveRegion: true,
                      child: Text(l.kioskSensorsStatus),
                    ),
                    children: [
                      _status(l.kioskSensorsLight, _light(l, snapshot)),
                      _status(l.kioskSensorsMotion, _motion(l, snapshot)),
                      _status(l.kioskSensorsApproach, _approach(l, snapshot)),
                      _status(l.kioskSensorsCamera, _camera(l, snapshot)),
                    ],
                  ),
                  if (!_foreground || !_nativeFocused)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l.kioskSensorsBackground),
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
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Semantics(
                      key: ValueKey(
                        snapshot == null
                            ? 'kiosk-sensor-start'
                            : 'kiosk-sensor-stop',
                      ),
                      button: true,
                      enabled: _foreground && !_pending,
                      child: FocusableActionDetector(
                        enabled: action != null,
                        shortcuts: const {
                          SingleActivator(LogicalKeyboardKey.enter):
                              ActivateIntent(),
                          SingleActivator(LogicalKeyboardKey.space):
                              ActivateIntent(),
                        },
                        actions: {
                          ActivateIntent: CallbackAction<ActivateIntent>(
                            onInvoke: (_) {
                              action?.call();
                              return null;
                            },
                          ),
                        },
                        child: CupertinoButton.filled(
                          minimumSize: const Size.fromHeight(48),
                          onPressed: action,
                          child: _pending
                              ? const CupertinoActivityIndicator()
                              : Text(
                                  snapshot == null
                                      ? l.kioskSensorsStart
                                      : l.kioskSensorsStop,
                                ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(l.kioskSensorsPrivacy, style: AppText.footnote),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _light(AppLocalizations l, KioskSensorSnapshot? value) {
    if (value == null) return l.kioskSensorsInactive;
    if (!value.lightAvailable) return l.kioskSensorsNotAvailable;
    if (value.lux == null) return l.kioskSensorsWaiting;
    return l.kioskSensorsLux(
      value.lux!.toStringAsFixed(1),
      value.isDark == true ? l.kioskSensorsDark : l.kioskSensorsBright,
    );
  }

  String _motion(AppLocalizations l, KioskSensorSnapshot? value) {
    if (value == null) return l.kioskSensorsInactive;
    if (!value.motionAvailable) return l.kioskSensorsNotAvailable;
    if (value.motionDelta == null) return l.kioskSensorsWaiting;
    return value.isMoving(_sensitivity) == true
        ? l.kioskSensorsMoving
        : l.kioskSensorsStill;
  }

  String _camera(AppLocalizations l, KioskSensorSnapshot? value) {
    if (value == null) return l.kioskSensorsCameraOff;
    return switch (value.cameraStatus) {
      KioskSensorCameraStatus.available => l.kioskSensorsCameraAvailable,
      KioskSensorCameraStatus.busy => l.kioskSensorsCameraBusy,
      KioskSensorCameraStatus.permissionDenied =>
        l.kioskSensorsCameraPermissionDenied,
      KioskSensorCameraStatus.unavailable => l.kioskSensorsNotAvailable,
    };
  }

  String _approach(AppLocalizations l, KioskSensorSnapshot? value) {
    if (value == null) return l.kioskSensorsInactive;
    if (!value.approachAvailable) return l.kioskSensorsNotAvailable;
    return switch (value.isApproached) {
      true => l.kioskSensorsApproachNearby,
      false => l.kioskSensorsApproachClear,
      null => l.kioskSensorsWaiting,
    };
  }

  Widget _segment(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    child: Text(label),
  );

  Widget _status(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.footnote),
        const SizedBox(height: 4),
        Text(value, style: AppText.headline),
      ],
    ),
  );
}
