import 'dart:async';

import '../domain/energy_models.dart';
import 'energy_repository.dart';

/// One account, one serial reader. Construction is inert; only an active,
/// visible foreground subscription starts or schedules work.
class EnergyController {
  EnergyController({
    required this.repository,
    this.interval = const Duration(minutes: 5),
  });
  final EnergyRepository repository;
  final Duration interval;
  final _changes = StreamController<EnergyViewState>.broadcast();
  EnergyViewState _state = const EnergyViewState();
  EnergyRange _range = EnergyRange.today;
  Timer? _timer;
  Future<void>? _reading;
  int _listeners = 0, _generation = 0;
  bool _foreground = true, _visible = true, _disposed = false, _pending = false;
  EnergyRange get range => _range;
  EnergyViewState get state => _state;
  bool get _active => !_disposed && _listeners > 0 && _foreground && _visible;

  Stream<EnergyViewState> get changes => Stream.multi((sink) {
    if (_disposed) {
      sink.close();
      return;
    }
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    _listeners++;
    sink.add(_state);
    if (_listeners == 1 && _active) unawaited(refresh());
    sink.onCancel = () async {
      _listeners--;
      if (_listeners == 0) _pause();
      await subscription.cancel();
    };
  }, isBroadcast: true);

  Future<void> refresh() {
    if (!_active) return Future.value();
    _timer?.cancel();
    if (_reading != null) {
      _pending = true;
      return _reading!;
    }
    final generation = _generation;
    final selected = _range;
    _publish(EnergyViewState(snapshot: _state.snapshot, isRefreshing: true));
    final future = _load(selected, generation);
    _reading = future;
    return future.whenComplete(() {
      _reading = null;
      if (_pending && _active) {
        _pending = false;
        unawaited(refresh());
      } else if (_active) {
        _timer = Timer(interval, () => unawaited(refresh()));
      }
    });
  }

  Future<void> _load(EnergyRange range, int generation) async {
    bool current() => _active && generation == _generation;
    try {
      final result = await repository.load(range, isCurrent: current);
      if (current()) _publish(EnergyViewState(snapshot: result));
    } on EnergyReadCancelled {
      /* Intentional visibility/account cancellation. */
    } catch (error) {
      if (current()) {
        _publish(EnergyViewState(failure: classifyEnergyFailure(error)));
      }
    }
  }

  void setRange(EnergyRange value) {
    if (_disposed || _range == value) return;
    _range = value;
    _pause();
    _publish(const EnergyViewState());
    if (_active) unawaited(refresh());
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _pause();
    if (_active) unawaited(refresh());
  }

  /// The owning page must set false when covered/hidden but kept mounted.
  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _pause();
    if (_active) unawaited(refresh());
  }

  void _pause() {
    _generation++;
    _pending = false;
    _timer?.cancel();
    if (_state.isRefreshing) {
      _state = EnergyViewState(snapshot: _state.snapshot);
    }
  }

  void _publish(EnergyViewState value) {
    if (_disposed) return;
    _state = value;
    _changes.add(value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pause();
    _state = const EnergyViewState(connectionConfigured: false);
    unawaited(_changes.close());
  }
}
