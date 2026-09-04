import 'dart:async';

import 'action_receipt.dart';
import 'integration_health.dart';

class _PendingAction {
  _PendingAction(this.receipt);
  ActionReceipt receipt;
  final result = Completer<ActionReceipt>();
  StreamSubscription<dynamic>? observation;
  Timer? timeout;
  DateTime? matchedAt;
  bool dispatched = false;
  bool observationLost = false;
}

/// A bounded, memory-only receipt history and per-target concurrency guard.
/// No command is retried, persisted, queued offline or replayed on reconnect.
class ActionController {
  ActionController({DateTime Function()? now, this.historyLimit = 50})
    : _now = now ?? DateTime.now {
    if (historyLimit < 1 || historyLimit > 500) {
      throw ArgumentError('Invalid receipt history limit.');
    }
  }

  final DateTime Function() _now;
  final int historyLimit;
  final _pending = <String, _PendingAction>{};
  final _history = <ActionReceipt>[];
  final _changes = StreamController<List<ActionReceipt>>.broadcast();
  int _nextId = 1;
  bool _disposed = false;

  List<ActionReceipt> get receipts => List.unmodifiable(_history);
  bool get hasPending => _pending.isNotEmpty;

  Stream<List<ActionReceipt>> get changes => Stream.multi((sink) {
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    sink.add(receipts);
    sink.onCancel = subscription.cancel;
  }, isBroadcast: true);

  bool isPending(ActionKey key) => _pending.containsKey(_targetKey(key));

  Future<ActionReceipt> execute<T>({
    required ActionKey key,
    required Future<void> Function() send,
    Stream<T>? observations,
    bool Function(T value)? confirms,
    ActionFailure Function(Object error)? classifyFailure,
    Duration acknowledgementTimeout = const Duration(seconds: 30),
    Duration confirmationTimeout = const Duration(seconds: 10),
  }) {
    if (_disposed) throw StateError('Action controller is disposed.');
    if ((observations == null) != (confirms == null) ||
        acknowledgementTimeout <= Duration.zero ||
        confirmationTimeout <= Duration.zero) {
      throw ArgumentError('Invalid action observation or timeout.');
    }
    final target = _targetKey(key);
    final existing = _pending[target];
    if (existing != null) throw ActionInProgressException(existing.receipt.id);
    final pending = _PendingAction(
      ActionReceipt(
        id: _nextId++,
        key: key,
        createdAt: _now(),
        status: ActionStatus.sending,
      ),
    );
    _pending[target] = pending;
    _publish(pending.receipt);

    // Subscribe before dispatch so fast device updates cannot beat the ACK.
    // Initial replay values emitted synchronously by a stream are ignored.
    pending.observation = observations?.listen(
      (value) {
        if (!pending.dispatched || !_active(target, pending)) return;
        bool matches;
        try {
          matches = confirms!(value);
        } catch (_) {
          _observationLost(target, pending);
          return;
        }
        if (!matches) {
          pending.matchedAt = null;
          return;
        }
        pending.matchedAt = _now();
        if (pending.receipt.status == ActionStatus.accepted) {
          _finish(target, pending, ActionStatus.confirmed);
        }
      },
      onError: (Object _) => _observationLost(target, pending),
      onDone: () => _observationLost(target, pending),
    );

    pending.timeout = Timer(acknowledgementTimeout, () {
      _finish(target, pending, ActionStatus.unknown, ActionFailure.timeout);
    });
    pending.dispatched = true;
    unawaited(
      Future<void>.sync(send).then(
        (_) {
          if (!_active(target, pending)) return;
          pending.timeout?.cancel();
          pending.receipt = pending.receipt.update(
            status: ActionStatus.accepted,
            acceptedAt: _now(),
          );
          _publish(pending.receipt);
          if (observations == null) {
            _finish(target, pending, ActionStatus.accepted);
          } else if (pending.matchedAt != null) {
            _finish(target, pending, ActionStatus.confirmed);
          } else if (pending.observationLost) {
            _finish(
              target,
              pending,
              ActionStatus.unknown,
              ActionFailure.observationLost,
            );
          } else {
            pending.timeout = Timer(confirmationTimeout, () {
              _finish(
                target,
                pending,
                ActionStatus.unknown,
                ActionFailure.timeout,
              );
            });
          }
        },
        onError: (Object error) {
          if (!_active(target, pending)) return;
          var reason = ActionFailure.unknown;
          try {
            reason = classifyFailure?.call(error) ?? reason;
          } catch (_) {
            // Never retain or surface arbitrary error text from providers.
          }
          final knownRejection = {
            ActionFailure.authentication,
            ActionFailure.permission,
            ActionFailure.rejected,
            ActionFailure.notConnected,
          }.contains(reason);
          _finish(
            target,
            pending,
            knownRejection ? ActionStatus.failed : ActionStatus.unknown,
            reason,
          );
        },
      ),
    );
    return pending.result.future;
  }

  void _observationLost(String target, _PendingAction pending) {
    if (!_active(target, pending)) return;
    pending.observationLost = true;
    if (pending.receipt.status == ActionStatus.accepted) {
      _finish(
        target,
        pending,
        ActionStatus.unknown,
        ActionFailure.observationLost,
      );
    }
  }

  bool _active(String target, _PendingAction pending) =>
      identical(_pending[target], pending);

  void _finish(
    String target,
    _PendingAction pending,
    ActionStatus status, [
    ActionFailure? failure,
  ]) {
    if (!_active(target, pending)) return;
    _pending.remove(target);
    pending.timeout?.cancel();
    unawaited(pending.observation?.cancel());
    pending.receipt = pending.receipt.update(
      status: status,
      observedAt: status == ActionStatus.confirmed ? pending.matchedAt : null,
      completedAt: _now(),
      failure: failure,
    );
    _publish(pending.receipt);
    pending.result.complete(pending.receipt);
  }

  void _publish(ActionReceipt receipt) {
    _history.removeWhere((value) => value.id == receipt.id);
    _history.insert(0, receipt);
    if (_history.length > historyLimit) _history.removeLast();
    if (!_disposed) _changes.add(receipts);
  }

  String _targetKey(ActionKey key) => '${key.integration.name}:${key.target}';

  /// Commands already sent cannot be recalled. Resolve their old caller as
  /// unknown, then remove the old account's guards and visible receipts.
  void resetIntegration(IntegrationId integration) {
    if (_disposed) return;
    for (final entry in _pending.entries.toList()) {
      if (entry.value.receipt.key.integration != integration) continue;
      _finish(
        entry.key,
        entry.value,
        ActionStatus.unknown,
        ActionFailure.disposed,
      );
    }
    _history.removeWhere((receipt) => receipt.key.integration == integration);
    _changes.add(receipts);
  }

  void dispose() {
    if (_disposed) return;
    for (final entry in _pending.entries.toList()) {
      _finish(
        entry.key,
        entry.value,
        ActionStatus.unknown,
        ActionFailure.disposed,
      );
    }
    _disposed = true;
    unawaited(_changes.close());
  }
}
