import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/idle_prevention.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../kiosk/data/kiosk_sensor_api.dart';
import '../../kiosk/data/kiosk_sensor_controller.dart';
import '../../kiosk/domain/kiosk_sensor_models.dart';
import '../providers/settings_providers.dart';
import '../../ambient/presentation/ambient_screen.dart';

/// An ambient clock after inactivity. Its first input wakes the window only;
/// the mounted application and native audio service retain their lifetimes.
class IdleGate extends ConsumerStatefulWidget {
  const IdleGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IdleGate> createState() => _IdleGateState();
}

class _IdleGateState extends ConsumerState<IdleGate>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _approachPoller;
  bool _idle = false;
  bool _foreground = true;
  bool _focused = true;
  int? _viewId;
  bool _wakingKeyboard = false;
  final _focusScope = FocusScopeNode(debugLabel: 'Application interaction');
  final _clockFocus = FocusNode(debugLabel: 'Ambient clock');
  late final AppInteractionController _interaction;
  late final IdlePreventionController _prevention;
  late KioskSensorController _approachController;
  int _approachEpoch = 0;
  bool _approachReadBusy = false;

  bool get _windowActive => _foreground && _focused;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _interaction = AppInteractionController(active: _foreground);
    _prevention = ref.read(idlePreventionProvider);
    // Ambient wake owns a separate controller. A manual KioskSensorScreen may
    // already own the single native session; a busy start here must never stop
    // or retire that screen's session.
    _approachController = KioskSensorController(AndroidKioskSensorApi());
    _prevention.addListener(_preventionChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_keyEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resetTimer();
    });
  }

  @override
  void dispose() {
    _prevention.removeListener(_preventionChanged);
    _timer?.cancel();
    _approachEpoch++;
    _approachPoller?.cancel();
    unawaited(_approachController.retire());
    FocusManager.instance.removeEarlyKeyEventHandler(_keyEvent);
    _focusScope.dispose();
    _clockFocus.dispose();
    _interaction.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
  }

  void _preventionChanged() {
    _timer?.cancel();
    // A video can acquire its lease while its page is building. Reconcile the
    // overlay after that frame rather than rebuilding an ancestor mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resetTimer();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasActive = _windowActive;
    _foreground = state == AppLifecycleState.resumed;
    _wakingKeyboard = false;
    _resetTimer();
    if (mounted && wasActive != _windowActive) setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    final wasActive = _windowActive;
    _focused = event.state == ViewFocusState.focused;
    _wakingKeyboard = false;
    // A DeX window can lose focus while the app is still resumed. Retire its
    // captured actions before another frame, without unmounting native audio.
    _resetTimer();
    if (mounted && wasActive != _windowActive) setState(() {});
  }

  KeyEventResult _keyEvent(KeyEvent event) {
    if (!mounted || !_windowActive) return KeyEventResult.ignored;
    // FocusManager is process-wide. Ignore another mounted app/window's focus.
    final primary = FocusManager.instance.primaryFocus;
    if (primary != _focusScope &&
        primary?.ancestors.contains(_focusScope) != true) {
      return KeyEventResult.ignored;
    }
    final consume = _idle || _wakingKeyboard;
    if (_idle) _wakingKeyboard = true;
    _resetTimer();
    if (consume) {
      // A wake chord (Ctrl then K, or held Enter) is one interaction. Do not
      // allow its remaining down/repeat/up events to reach application actions.
      if (HardwareKeyboard.instance.physicalKeysPressed.isEmpty) {
        _wakingKeyboard = false;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _resetTimer() {
    if (!mounted) return;
    _timer?.cancel();
    unawaited(_retireApproach());
    final wasIdle = _idle;
    _idle = false;
    _interaction.setActive(_windowActive);
    if (wasIdle) setState(() {});

    final reading = ref.read(idleModeProvider);
    final settings = reading.isLoading || reading.hasError
        ? null
        : reading.value;
    if (!_windowActive ||
        _prevention.prevented ||
        settings == null ||
        !settings.enabled) {
      return;
    }
    if (settings.timeoutSeconds < 30 || settings.timeoutSeconds > 86400) return;

    _timer = Timer(Duration(seconds: settings.timeoutSeconds), () {
      if (!mounted || !_windowActive) return;
      // Notify action owners synchronously, before rebuilding the Navigator's
      // TickerMode. They can expire/remove their pending confirmation safely.
      _interaction.setActive(false);
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _idle = true);
      unawaited(_startApproachWake());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _idle && _windowActive) _clockFocus.requestFocus();
      });
    });
  }

  Future<void> _startApproachWake() async {
    final settings = ref.read(idleModeProvider).value;
    if (!_idle ||
        !_windowActive ||
        settings == null ||
        !settings.enabled ||
        !settings.wakeOnApproach) {
      return;
    }
    final epoch = ++_approachEpoch;
    _approachPoller?.cancel();
    try {
      final initial = await _approachController.start(intervalMillis: 1000);
      if (!_approachCurrent(epoch) ||
          initial.powerLimited ||
          !initial.approachAvailable) {
        await _retireApproach();
        return;
      }
      _approachPoller = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_pollApproach(epoch)),
      );
    } on KioskSensorException {
      await _retireApproach();
    }
  }

  bool _approachCurrent(int epoch) {
    final settings = ref.read(idleModeProvider).value;
    return mounted &&
        epoch == _approachEpoch &&
        _idle &&
        _windowActive &&
        settings?.enabled == true &&
        settings?.wakeOnApproach == true;
  }

  Future<void> _pollApproach(int epoch) async {
    if (_approachReadBusy) return;
    if (!_approachCurrent(epoch)) {
      await _retireApproach();
      return;
    }
    _approachReadBusy = true;
    try {
      final value = await _approachController.refresh();
      if (!_approachCurrent(epoch)) return;
      if (value.powerLimited || !value.approachAvailable) {
        await _retireApproach();
      } else if (value.isApproached == true) {
        _resetTimer();
      }
    } on KioskSensorException catch (error) {
      if (error.failure != KioskSensorFailure.busy) {
        await _retireApproach();
      }
    } finally {
      _approachReadBusy = false;
    }
  }

  Future<void> _retireApproach() async {
    _approachEpoch++;
    _approachPoller?.cancel();
    _approachPoller = null;
    await _approachController.retire();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(idleModeProvider, (_, _) => _resetTimer());

    return AppInteractionScope(
      controller: _interaction,
      child: FocusScope(
        node: _focusScope,
        autofocus: true,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _resetTimer(),
          onPointerMove: (_) => _resetTimer(),
          onPointerSignal: (_) => _resetTimer(),
          onPointerPanZoomStart: (_) => _resetTimer(),
          onPointerPanZoomUpdate: (_) => _resetTimer(),
          onPointerPanZoomEnd: (_) => _resetTimer(),
          child: Stack(
            children: [
              TickerMode(
                enabled: _windowActive && !_idle,
                child: ExcludeFocus(
                  excluding: !_windowActive || _idle,
                  child: ExcludeSemantics(
                    excluding: !_windowActive || _idle,
                    child: IgnorePointer(
                      ignoring: !_windowActive || _idle,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
              if (_idle)
                Positioned.fill(
                  child: Focus(
                    focusNode: _clockFocus,
                    child: Semantics(
                      button: true,
                      label: AppLocalizations.of(context).idleWakeHint,
                      onTap: _resetTimer,
                      child: const Listener(
                        // Only the clock participates in the wake gesture's
                        // hit-test path, including its later move/up events.
                        behavior: HitTestBehavior.opaque,
                        child: AmbientScreen(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
