import 'dart:async';

import '../../data/media_api_exception.dart';
import '../../jellyfin/data/models/jellyfin_item.dart';
import '../domain/remote_playback_models.dart';
import 'remote_playback_api.dart';

/// Created only after fresh item metadata; never persisted or restored.
class RemotePlaybackIntent {
  RemotePlaybackIntent._(
    this._owner,
    this._generation,
    this.target,
    this.itemId,
    this.itemTitle,
    this.startPosition,
    this.expiresAt,
  );
  final Object _owner;
  final int _generation;
  bool _used = false;
  final RemotePlaybackTarget target;
  final String itemId, itemTitle;
  final Duration startPosition;
  final DateTime expiresAt;
}

class RemotePlaybackController {
  RemotePlaybackController({
    required this.api,
    required String userId,
    required this.localDeviceId,
    required this.isCurrent,
    DateTime Function()? now,
  }) : userId = remoteItemId(userId),
       _now = now ?? DateTime.now;
  final RemotePlaybackApi api;
  final String userId, localDeviceId;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final Object _owner = Object();
  final _changes = StreamController<RemotePlaybackSnapshot>.broadcast();
  RemotePlaybackSnapshot _state = RemotePlaybackSnapshot();
  RemotePlaybackSnapshot get state => _state;
  int _listeners = 0, _generation = 0, _observation = 0;
  bool _foreground = true,
      _visible = true,
      _disposed = false,
      _busy = false,
      _refreshAgain = false;
  Future<void>? _refreshing;
  Timer? _timer;
  bool get _active =>
      !_disposed && _foreground && _visible && _listeners > 0 && isCurrent();

  Stream<RemotePlaybackSnapshot> get changes => Stream.multi((sink) {
    if (_disposed) {
      sink.close();
      return;
    }
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    _listeners++;
    sink.add(_state);
    if (_listeners == 1 && _active) unawaited(refresh());
    sink.onCancel = () {
      _listeners--;
      if (_listeners == 0) _invalidate();
      return subscription.cancel();
    };
  }, isBroadcast: true);

  void _check(int generation) {
    if (!_active || generation != _generation) {
      throw const RemotePlaybackException(RemotePlaybackFailure.invalidIntent);
    }
  }

  List<RemotePlaybackTarget> _eligible(List<RemotePlaybackTarget> targets) =>
      targets
          .where(
            (target) => target.eligibleFor(
              userId: userId,
              localDeviceId: localDeviceId,
            ),
          )
          .toList(growable: false);
  Future<T> _read<T>(Future<T> Function() read) =>
      read().timeout(const Duration(seconds: 15));
  void _publish(RemotePlaybackSnapshot value) {
    if (_disposed) return;
    _state = value;
    _changes.add(value);
  }

  RemotePlaybackSnapshot _copy({
    bool? loading,
    bool? busy,
    List<RemotePlaybackTarget>? targets,
    DateTime? readAt,
    RemotePlaybackFailure? failure,
    RemotePlaybackReceipt? receipt,
    bool outcomeUnknown = false,
    bool clearReceipt = false,
  }) => RemotePlaybackSnapshot(
    configured: _state.configured,
    isLoading: loading ?? _state.isLoading,
    isBusy: busy ?? _busy,
    targets: targets ?? _state.targets,
    readAt: readAt ?? _state.readAt,
    failure: failure,
    outcomeUnknown: outcomeUnknown,
    receipt: clearReceipt ? null : receipt ?? _state.receipt,
  );

  Future<void> refresh() {
    if (!_active) return Future.value();
    if (_busy) {
      _refreshAgain = true;
      return Future.value();
    }
    if (_refreshing != null) {
      _refreshAgain = true;
      return _refreshing!;
    }
    _stopObservation();
    return _refreshing = _refresh(_generation).whenComplete(() {
      _refreshing = null;
      if (_refreshAgain && _active) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _refresh(int generation) async {
    _publish(_copy(loading: true));
    try {
      final targets = _eligible(await _read(api.getTargets));
      _check(generation);
      final receipt = _state.receipt;
      RemotePlaybackReceipt? updated;
      if (receipt != null &&
          receipt.status != RemotePlaybackReceiptStatus.observed) {
        final target = targets
            .where((value) => value.sameIdentity(receipt.target))
            .firstOrNull;
        final observed = _observesPlayback(target, receipt);
        updated = RemotePlaybackReceipt(
          status: observed
              ? RemotePlaybackReceiptStatus.observed
              : RemotePlaybackReceiptStatus.unconfirmed,
          target: receipt.target,
          itemId: receipt.itemId,
          acceptedAt: receipt.acceptedAt,
          observedAt: observed ? _now().toUtc() : null,
        );
      }
      _publish(
        _copy(
          loading: false,
          targets: targets,
          readAt: _now().toUtc(),
          receipt: updated,
        ),
      );
    } catch (error) {
      if (_active && generation == _generation) {
        _publish(
          _copy(
            loading: false,
            targets: [],
            failure: remotePlaybackFailure(error),
          ),
        );
      }
    }
  }

  Future<RemotePlaybackIntent> createIntent(
    RemotePlaybackTarget target,
    String itemId, {
    Duration startPosition = Duration.zero,
  }) async {
    final generation = _generation;
    _check(generation);
    if (_busy || _state.isLoading) {
      throw const RemotePlaybackException(RemotePlaybackFailure.busy);
    }
    final known = _state.targets
        .where((value) => value.sameIdentity(target))
        .firstOrNull;
    if (known == null || _state.failure != null) {
      throw const RemotePlaybackException(RemotePlaybackFailure.unavailable);
    }
    final id = remoteItemId(itemId);
    _busy = true;
    _stopObservation();
    _publish(_copy(busy: true));
    try {
      final item = await _read(() => api.getItem(id));
      _check(generation);
      _validateItem(item, id, startPosition);
      return RemotePlaybackIntent._(
        _owner,
        generation,
        known,
        id,
        item.name,
        startPosition,
        _now().toUtc().add(const Duration(seconds: 30)),
      );
    } catch (error) {
      throw RemotePlaybackException(remotePlaybackFailure(error));
    } finally {
      _finishOperation();
      if (_active && generation == _generation) _publish(_copy(busy: false));
    }
  }

  void _validateItem(JellyfinItem item, String id, Duration position) {
    final ticks = position.inMicroseconds * 10;
    if (remoteItemId(item.id) != id ||
        !item.isPlayable ||
        ticks < 0 ||
        ticks > remoteMaximumPositionTicks ||
        (ticks > 0 &&
            (item.runTimeTicks == null || ticks >= item.runTimeTicks!))) {
      throw const RemotePlaybackException(
        RemotePlaybackFailure.unsupportedItem,
      );
    }
  }

  Future<RemotePlaybackReceipt> play(RemotePlaybackIntent intent) async {
    final generation = _generation;
    _check(generation);
    if (_busy || _refreshing != null || _state.isLoading) {
      throw const RemotePlaybackException(RemotePlaybackFailure.busy);
    }
    if (!identical(intent._owner, _owner) ||
        intent._generation != generation ||
        intent._used) {
      throw const RemotePlaybackException(RemotePlaybackFailure.invalidIntent);
    }
    intent._used = true;
    if (!_now().toUtc().isBefore(intent.expiresAt)) {
      throw const RemotePlaybackException(RemotePlaybackFailure.expiredIntent);
    }
    _busy = true;
    _stopObservation();
    _publish(_copy(busy: true, clearReceipt: true));
    var dispatched = false;
    try {
      final item = await _read(() => api.getItem(intent.itemId));
      _check(generation);
      _validateItem(item, intent.itemId, intent.startPosition);
      final targets = _eligible(await _read(api.getTargets));
      _check(generation);
      final target = targets
          .where((value) => value.sameIdentity(intent.target))
          .firstOrNull;
      if (target == null) {
        throw const RemotePlaybackException(RemotePlaybackFailure.unavailable);
      }
      if (!_now().toUtc().isBefore(intent.expiresAt)) {
        throw const RemotePlaybackException(
          RemotePlaybackFailure.expiredIntent,
        );
      }
      // No await between the final generation/identity check and dispatch.
      _check(generation);
      dispatched = true;
      await api
          .play(
            sessionId: target.sessionId,
            itemId: intent.itemId,
            startPosition: intent.startPosition,
          )
          .timeout(const Duration(seconds: 15));
      _check(generation);
      final receipt = RemotePlaybackReceipt(
        status: RemotePlaybackReceiptStatus.accepted,
        target: target,
        itemId: intent.itemId,
        acceptedAt: _now().toUtc(),
      );
      _publish(
        _copy(
          busy: false,
          targets: targets,
          readAt: _now().toUtc(),
          receipt: receipt,
        ),
      );
      _scheduleObservation(receipt, generation, _observation, 0);
      return receipt;
    } catch (error) {
      final failure = remotePlaybackFailure(error);
      final uncertain =
          dispatched &&
          {
            RemotePlaybackFailure.transport,
            RemotePlaybackFailure.timeout,
            RemotePlaybackFailure.invalidResponse,
          }.contains(failure);
      if (_active && generation == _generation) {
        _publish(
          _copy(busy: false, failure: failure, outcomeUnknown: uncertain),
        );
      }
      throw RemotePlaybackException(failure, outcomeUnknown: uncertain);
    } finally {
      _finishOperation();
    }
  }

  void _scheduleObservation(
    RemotePlaybackReceipt receipt,
    int generation,
    int observation,
    int attempt,
  ) {
    if (!_active || generation != _generation || observation != _observation) {
      return;
    }
    final delay = [1, 2, 3][attempt];
    _timer = Timer(
      Duration(seconds: delay),
      () => unawaited(_observe(receipt, generation, observation, attempt)),
    );
  }

  Future<void> _observe(
    RemotePlaybackReceipt receipt,
    int generation,
    int observation,
    int attempt,
  ) async {
    bool current() =>
        _active && generation == _generation && observation == _observation;
    if (!current()) return;
    try {
      final targets = _eligible(await _read(api.getTargets));
      if (!current()) return;
      final target = targets
          .where((value) => value.sameIdentity(receipt.target))
          .firstOrNull;
      final observed = _observesPlayback(target, receipt);
      if (observed || attempt == 2 || target == null) {
        _publish(
          _copy(
            targets: targets,
            readAt: _now().toUtc(),
            receipt: RemotePlaybackReceipt(
              status: observed
                  ? RemotePlaybackReceiptStatus.observed
                  : RemotePlaybackReceiptStatus.unconfirmed,
              target: receipt.target,
              itemId: receipt.itemId,
              acceptedAt: receipt.acceptedAt,
              observedAt: observed ? _now().toUtc() : null,
            ),
          ),
        );
      } else {
        _scheduleObservation(receipt, generation, observation, attempt + 1);
      }
    } catch (error) {
      if (current()) {
        _publish(
          _copy(
            targets: [],
            failure: remotePlaybackFailure(error),
            receipt: RemotePlaybackReceipt(
              status: RemotePlaybackReceiptStatus.unconfirmed,
              target: receipt.target,
              itemId: receipt.itemId,
              acceptedAt: receipt.acceptedAt,
            ),
          ),
        );
      }
    }
  }

  bool _observesPlayback(
    RemotePlaybackTarget? target,
    RemotePlaybackReceipt receipt,
  ) {
    final checkIn = target?.lastPlaybackCheckIn;
    final baseline = receipt.target.lastPlaybackCheckIn;
    final changed =
        target?.nowPlayingItemId != receipt.target.nowPlayingItemId ||
        (receipt.target.isPaused == true && target?.isPaused == false) ||
        (checkIn != null && baseline != null && checkIn.isAfter(baseline));
    return target?.nowPlayingItemId == receipt.itemId &&
        target?.isPaused == false &&
        changed;
  }

  void _finishOperation() {
    _busy = false;
    if (_refreshAgain && _active) {
      _refreshAgain = false;
      unawaited(refresh());
    }
  }

  void _stopObservation() {
    _observation++;
    _timer?.cancel();
    _timer = null;
  }

  void _invalidate() {
    _generation++;
    _refreshAgain = false;
    _stopObservation();
    // Clear no-longer-current receiver evidence, while retaining no command.
    _publish(RemotePlaybackSnapshot(configured: !_disposed));
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _invalidate();
    if (_active) unawaited(refresh());
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _invalidate();
    if (_active) unawaited(refresh());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidate();
    _state = RemotePlaybackSnapshot(configured: false);
    unawaited(_changes.close());
  }
}

RemotePlaybackFailure remotePlaybackFailure(Object error) {
  if (error is RemotePlaybackException) return error.failure;
  if (error is TimeoutException) return RemotePlaybackFailure.timeout;
  if (error is MediaApiException) {
    if (error.statusCode == 401) return RemotePlaybackFailure.authentication;
    if (error.statusCode == 403) return RemotePlaybackFailure.permission;
    return RemotePlaybackFailure.transport;
  }
  if (error is FormatException || error is TypeError) {
    return RemotePlaybackFailure.invalidResponse;
  }
  return RemotePlaybackFailure.transport;
}
