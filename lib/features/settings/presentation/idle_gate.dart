import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/idle_prevention.dart';
import '../../../l10n/generated/app_localizations.dart';
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
  bool _idle = false;
  bool _foreground = true;
  bool _focused = true;
  int? _viewId;
  bool _wakingKeyboard = false;
  final _focusScope = FocusScopeNode(debugLabel: 'Application interaction');
  final _clockFocus = FocusNode(debugLabel: 'Ambient clock');
  late final AppInteractionController _interaction;
  late final IdlePreventionController _prevention;

  bool get _windowActive => _foreground && _focused;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _interaction = AppInteractionController(active: _foreground);
    _prevention = ref.read(idlePreventionProvider);
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
    if (settings.timeoutMinutes < 1 || settings.timeoutMinutes > 1440) return;

    _timer = Timer(Duration(minutes: settings.timeoutMinutes), () {
      if (!mounted || !_windowActive) return;
      // Notify action owners synchronously, before rebuilding the Navigator's
      // TickerMode. They can expire/remove their pending confirmation safely.
      _interaction.setActive(false);
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _idle = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _idle && _windowActive) _clockFocus.requestFocus();
      });
    });
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
