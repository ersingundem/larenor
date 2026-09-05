import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Leases prevent the ambient overlay, not the OS screen timeout or app locking.
final idlePreventionProvider = Provider<IdlePreventionController>((ref) {
  final controller = IdlePreventionController();
  ref.onDispose(controller.dispose);
  return controller;
});

class IdlePreventionController extends ChangeNotifier {
  final _owners = <Object>{};
  bool _disposed = false;
  bool get prevented => _owners.isNotEmpty;
  void set(Object owner, bool active) {
    if (_disposed) return;
    final previous = prevented;
    active ? _owners.add(owner) : _owners.remove(owner);
    if (previous != prevented) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _owners.clear();
    super.dispose();
  }
}

class PreventAmbientDisplay extends ConsumerStatefulWidget {
  const PreventAmbientDisplay({
    super.key,
    required this.active,
    required this.child,
  });
  final bool active;
  final Widget child;
  @override
  ConsumerState<PreventAmbientDisplay> createState() =>
      _PreventAmbientDisplayState();
}

class _PreventAmbientDisplayState extends ConsumerState<PreventAmbientDisplay>
    with WidgetsBindingObserver {
  final _owner = Object();
  late final IdlePreventionController _controller;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(idlePreventionProvider);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PreventAmbientDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() => _controller.set(
    _owner,
    mounted &&
        widget.active &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false,
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    _controller.set(_owner, false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
