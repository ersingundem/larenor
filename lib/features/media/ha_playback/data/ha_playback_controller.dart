import 'dart:async';

import '../domain/ha_media_inventory.dart';
import '../domain/ha_playback_models.dart';
import 'ha_playback_api.dart';

/// Account/session scoped; never serialized. Only this controller can issue one.
class HaPlaybackIntent {
  HaPlaybackIntent._(
    this._owner,
    this._generation,
    this.source,
    this.target,
    this._parentId,
    this.expiresAt,
  );
  final Object _owner;
  final int _generation;
  final String _parentId;
  bool _used = false;
  final HaMediaNode source;
  final HaMediaTarget target;
  final DateTime expiresAt;
}

class HaPlaybackController {
  HaPlaybackController({
    required this.api,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _connection = api.connectionChanges.listen(
      (connected) {
        if (_disposed || connected == _connected) return;
        _connected = connected;
        _invalidate();
        if (_active) _resume();
      },
      onError: (_) {
        _connected = false;
        _invalidate();
      },
    );
  }
  final HaPlaybackApi api;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final Object _owner = Object();
  final _changes = StreamController<HaPlaybackSnapshot>.broadcast();
  final _ancestors = <HaMediaNode>[];
  StreamSubscription<bool>? _connection;
  HaPlaybackSnapshot _state = const HaPlaybackSnapshot();
  HaPlaybackSnapshot get state => _state;
  int _generation = 0, _listeners = 0, _observation = 0;
  bool _foreground = true,
      _visible = true,
      _connected = false,
      _disposed = false,
      _busy = false,
      _restartWhenIdle = false;
  Future<void>? _reading;
  Timer? _timer;
  bool get _active =>
      !_disposed &&
      _connected &&
      _foreground &&
      _visible &&
      _listeners > 0 &&
      isCurrent();
  Stream<HaPlaybackSnapshot> get changes => Stream.multi((sink) {
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
      throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
    }
  }

  Future<T> _read<T>(Future<T> Function() action) =>
      action().timeout(const Duration(seconds: 15));
  void _publish(HaPlaybackSnapshot next) {
    if (_disposed) return;
    _state = next;
    _changes.add(next);
  }

  HaPlaybackSnapshot _copy({
    bool? loading,
    bool? busy,
    HaMediaInventory? inventory,
    HaMediaBrowsePage? page,
    HaPlaybackFailure? failure,
    HaPlaybackReceipt? receipt,
    bool clearPage = false,
    bool clearInventory = false,
    bool clearReceipt = false,
    bool outcomeUnknown = false,
  }) => HaPlaybackSnapshot(
    isLoading: loading ?? _state.isLoading,
    isBusy: busy ?? _busy,
    inventory: clearInventory ? null : inventory ?? _state.inventory,
    page: clearPage ? null : page ?? _state.page,
    failure: failure,
    receipt: clearReceipt ? null : receipt ?? _state.receipt,
    outcomeUnknown: outcomeUnknown,
  );

  Future<void> refresh() {
    if (!_active) return Future.value();
    if (_busy) return Future.value();
    if (_reading != null) return _reading!;
    _generation++;
    _stopObservation();
    final generation = _generation;
    return _reading = _load(
      generation,
      _state.page?.parent.id,
    ).whenComplete(_finishRead);
  }

  Future<void> _load(int generation, String? parentId) async {
    _publish(_copy(loading: true, clearPage: true, clearInventory: true));
    try {
      final inventory = await _read(api.getInventory);
      _check(generation);
      final page = await _read(() => api.browse(parentId));
      _check(generation);
      _publish(_copy(loading: false, inventory: inventory, page: page));
    } catch (error) {
      if (_active && generation == _generation) {
        _publish(
          _copy(
            loading: false,
            clearPage: true,
            clearInventory: true,
            failure: haPlaybackFailure(error),
          ),
        );
      }
    }
  }

  Future<void> browse(HaMediaNode? node) {
    final generation = _generation;
    _check(generation);
    if (_busy || _reading != null) {
      throw const HaPlaybackException(HaPlaybackFailure.busy);
    }
    if (node != null) {
      final known =
          [...?_state.page?.children, ..._ancestors, ?_state.page?.parent]
              .where(
                (candidate) =>
                    candidate.sameSource(node) && candidate.canExpand,
              )
              .firstOrNull;
      if (known == null) {
        throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
      }
    }
    final page = _state.page;
    if (node == null) {
      _ancestors.clear();
    } else {
      final previousIndex = _ancestors.indexWhere(
        (value) => value.sameSource(node),
      );
      if (previousIndex >= 0) {
        _ancestors.removeRange(previousIndex, _ancestors.length);
      } else if (page != null && page.parent.id != node.id) {
        _ancestors.add(page.parent);
      }
    }
    _generation++;
    _stopObservation();
    return _reading = _load(_generation, node?.id).whenComplete(_finishRead);
  }

  Future<HaPlaybackIntent> createIntent(
    HaMediaNode source,
    HaMediaTarget target,
  ) async {
    final generation = _generation;
    _check(generation);
    if (_busy || _reading != null) {
      throw const HaPlaybackException(HaPlaybackFailure.busy);
    }
    final page = _state.page;
    final inventory = _state.inventory;
    if (page == null ||
        inventory == null ||
        _state.failure != null ||
        !page.children.any((value) => value.sameSource(source)) ||
        !inventory.targets.any((value) => value.sameIdentity(target))) {
      throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
    }
    if (!source.playable) {
      throw const HaPlaybackException(HaPlaybackFailure.unsupportedSource);
    }
    if (!target.canPlay(source, inventory)) {
      throw const HaPlaybackException(HaPlaybackFailure.unsupportedTarget);
    }
    _busy = true;
    _stopObservation();
    _publish(_copy(busy: true, clearReceipt: true));
    try {
      final fresh = await _preflight(
        generation,
        page.parent.id,
        source,
        target,
      );
      return HaPlaybackIntent._(
        _owner,
        generation,
        source,
        fresh.target,
        page.parent.id,
        _now().toUtc().add(const Duration(seconds: 30)),
      );
    } catch (error) {
      throw HaPlaybackException(haPlaybackFailure(error));
    } finally {
      _finishBusy();
    }
  }

  Future<({HaMediaTarget target, HaMediaInventory inventory})> _preflight(
    int generation,
    String parentId,
    HaMediaNode source,
    HaMediaTarget target,
  ) async {
    final page = await _read(() => api.browse(parentId));
    _check(generation);
    if (!page.children.any(
      (value) => value.sameSource(source) && value.playable,
    )) {
      throw const HaPlaybackException(HaPlaybackFailure.sourceChanged);
    }
    final inventory = await _read(api.getInventory);
    _check(generation);
    final fresh = inventory.targets
        .where((value) => value.sameIdentity(target))
        .firstOrNull;
    if (fresh == null || !fresh.canPlay(source, inventory)) {
      throw const HaPlaybackException(HaPlaybackFailure.unsupportedTarget);
    }
    return (target: fresh, inventory: inventory);
  }

  Future<HaPlaybackReceipt> play(HaPlaybackIntent intent) async {
    final generation = _generation;
    _check(generation);
    if (_busy || _reading != null) {
      throw const HaPlaybackException(HaPlaybackFailure.busy);
    }
    if (!identical(intent._owner, _owner) ||
        intent._generation != generation ||
        intent._used) {
      throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
    }
    intent._used = true;
    void current() {
      _check(generation);
      if (!_now().toUtc().isBefore(intent.expiresAt)) {
        throw const HaPlaybackException(HaPlaybackFailure.expiredIntent);
      }
    }

    current();
    _busy = true;
    _stopObservation();
    _publish(_copy(busy: true, clearReceipt: true));
    var dispatched = false;
    try {
      final fresh = await _preflight(
        generation,
        intent._parentId,
        intent.source,
        intent.target,
      );
      current();
      bool canSend() {
        try {
          current();
          return true;
        } on HaPlaybackException {
          return false;
        }
      }

      // The socket also checks this lease after its reconnect wait, before send.
      dispatched = true;
      await api
          .play(
            entityId: fresh.target.entityId,
            source: intent.source,
            isCurrent: canSend,
          )
          .timeout(const Duration(seconds: 30));
      _check(generation);
      final receipt = HaPlaybackReceipt(
        status: HaPlaybackReceiptStatus.accepted,
        target: fresh.target,
        source: intent.source,
        acceptedAt: _now().toUtc(),
      );
      _publish(
        _copy(busy: false, inventory: fresh.inventory, receipt: receipt),
      );
      _schedule(receipt, generation, _observation, 0);
      return receipt;
    } catch (error) {
      final failure = haPlaybackFailure(error);
      final unknown =
          dispatched &&
          !{
            HaPlaybackFailure.authentication,
            HaPlaybackFailure.permission,
            HaPlaybackFailure.invalidIntent,
            HaPlaybackFailure.expiredIntent,
          }.contains(failure);
      if (_active && generation == _generation) {
        _publish(_copy(busy: false, failure: failure, outcomeUnknown: unknown));
      }
      throw HaPlaybackException(failure, outcomeUnknown: unknown);
    } finally {
      _finishBusy();
    }
  }

  void _schedule(
    HaPlaybackReceipt receipt,
    int generation,
    int observation,
    int attempt,
  ) {
    if (!_active || generation != _generation || observation != _observation) {
      return;
    }
    _timer = Timer(
      Duration(seconds: [1, 2, 3][attempt]),
      () => unawaited(_observe(receipt, generation, observation, attempt)),
    );
  }

  Future<void> _observe(
    HaPlaybackReceipt receipt,
    int generation,
    int observation,
    int attempt,
  ) async {
    bool current() =>
        _active && generation == _generation && observation == _observation;
    if (!current()) return;
    try {
      final inventory = await _read(api.getInventory);
      if (!current()) return;
      final target = inventory.targets
          .where((value) => value.sameIdentity(receipt.target))
          .firstOrNull;
      final baseline = receipt.target;
      // Updating volume/position while the same item was already playing is
      // not evidence that this command started it. Never compare display title.
      final changed =
          baseline.mediaContentId != receipt.source.id ||
          baseline.state != 'playing';
      final observed =
          target != null &&
          target.state == 'playing' &&
          target.mediaContentId == receipt.source.id &&
          changed &&
          target.lastUpdated != null &&
          baseline.lastUpdated != null &&
          target.lastUpdated!.isAfter(baseline.lastUpdated!);
      if (observed || attempt == 2 || target == null) {
        _publish(
          _copy(
            inventory: inventory,
            receipt: HaPlaybackReceipt(
              status: observed
                  ? HaPlaybackReceiptStatus.observed
                  : HaPlaybackReceiptStatus.unconfirmed,
              target: receipt.target,
              source: receipt.source,
              acceptedAt: receipt.acceptedAt,
              observedAt: observed ? _now().toUtc() : null,
            ),
          ),
        );
      } else {
        _schedule(receipt, generation, observation, attempt + 1);
      }
    } catch (error) {
      if (current()) {
        _publish(
          _copy(
            clearInventory: true,
            failure: haPlaybackFailure(error),
            receipt: HaPlaybackReceipt(
              status: HaPlaybackReceiptStatus.unconfirmed,
              target: receipt.target,
              source: receipt.source,
              acceptedAt: receipt.acceptedAt,
            ),
          ),
        );
      }
    }
  }

  void cancelIntent() {
    _generation++;
    _stopObservation();
  }

  void _finishBusy() {
    _busy = false;
    if (_active) {
      _publish(
        _copy(
          busy: false,
          failure: _state.failure,
          outcomeUnknown: _state.outcomeUnknown,
        ),
      );
    }
    _restart();
  }

  void _finishRead() {
    _reading = null;
    _restart();
  }

  void _resume() {
    if (_reading != null || _busy) {
      _restartWhenIdle = true;
      return;
    }
    unawaited(refresh());
  }

  void _restart() {
    if (_restartWhenIdle && _active && _reading == null && !_busy) {
      _restartWhenIdle = false;
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
    _ancestors.clear();
    _restartWhenIdle = false;
    _stopObservation();
    _publish(const HaPlaybackSnapshot());
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _invalidate();
    if (_active) _resume();
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _invalidate();
    if (_active) _resume();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidate();
    _state = const HaPlaybackSnapshot(configured: false);
    unawaited(_connection?.cancel());
    unawaited(_changes.close());
  }
}
