import 'dart:async';

import '../../ha_playback/domain/ha_media_inventory.dart';
import '../../../ha_client/data/ha_api_exception.dart';
import '../domain/music_models.dart';
import '../domain/music_playback_models.dart';
import 'music_api.dart';
import 'music_playback_api.dart';
import 'music_repository.dart';

class MusicPlaybackIntent {
  MusicPlaybackIntent._(
    this._owner,
    this._epoch,
    this.source,
    this.target,
    this.createdAt,
    this.expiresAt,
  );
  final Object _owner;
  final int _epoch;
  bool _used = false;
  final MusicCatalogSelection source;
  final MusicQueueTarget target;
  final DateTime createdAt, expiresAt;
  MusicMediaItem get item => source.item;
}

/// Account-scoped, one-use explicit playback. Owns a repository whose inventory
/// loader performs a fresh HA read, independent of the passive catalog cache.
class MusicPlaybackController {
  MusicPlaybackController({
    required this.repository,
    required this.api,
    required this.isCurrent,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    _connection = api.connectionChanges.listen(
      (connected) {
        if (_closed || connected == _connected) return;
        _connected = connected;
        _invalidate();
      },
      onError: (_) {
        _connected = false;
        _invalidate();
      },
    );
  }
  final MusicRepository repository;
  final MusicPlaybackApi api;
  final bool Function() isCurrent;
  final DateTime Function() now;
  final Object _owner = Object();
  final _changes = StreamController<MusicPlaybackState>.broadcast();
  StreamSubscription<bool>? _connection;
  var _state = const MusicPlaybackState();
  MusicPlaybackState get state => _state;
  bool _closed = false,
      _foreground = true,
      _visible = false,
      _connected = false,
      _busy = false;
  int _epoch = 0;
  bool get isActive => _active;
  int get sessionGeneration => _epoch;
  bool get _active =>
      !_closed && _visible && _foreground && _connected && isCurrent();
  Stream<MusicPlaybackState> get changes => Stream.multi((sink) {
    if (_closed) {
      sink.close();
      return;
    }
    final subscription = _changes.stream.listen(sink.add, onDone: sink.close);
    sink.add(_state);
    sink.onCancel = subscription.cancel;
  }, isBroadcast: true);
  void _publish(MusicPlaybackState value) {
    if (_closed) return;
    _state = value;
    _changes.add(value);
  }

  void _invalidate() {
    _epoch++;
    _publish(MusicPlaybackState(isBusy: _busy));
  }

  void setVisible(bool value) {
    if (value == _visible) return;
    _visible = value;
    _invalidate();
  }

  void setForeground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    _invalidate();
  }

  void _check(int epoch, [MusicPlaybackIntent? intent]) {
    if (!_active || epoch != _epoch) {
      throw const MusicPlaybackException(MusicPlaybackFailure.invalidIntent);
    }
    if (intent != null &&
        (now().isBefore(intent.createdAt) ||
            !now().isBefore(intent.expiresAt))) {
      throw const MusicPlaybackException(MusicPlaybackFailure.expiredIntent);
    }
  }

  bool _current(int epoch, MusicPlaybackIntent intent) {
    try {
      _check(epoch, intent);
      return true;
    } on MusicPlaybackException {
      return false;
    }
  }

  Future<T> _read<T>(Future<T> Function() read) =>
      read().timeout(const Duration(seconds: 15));

  Future<MusicPlaybackIntent> createIntent({
    required MusicCatalogSelection source,
    required MusicQueueTarget target,
  }) async {
    if (_busy) throw const MusicPlaybackException(MusicPlaybackFailure.busy);
    if (!_active) {
      throw const MusicPlaybackException(MusicPlaybackFailure.invalidIntent);
    }
    _busy = true;
    final epoch = ++_epoch;
    _publish(const MusicPlaybackState(isBusy: true));
    try {
      await _preflight(source, target, epoch);
      _check(epoch);
      final created = now().toUtc();
      return MusicPlaybackIntent._(
        _owner,
        epoch,
        source,
        target,
        created,
        created.add(const Duration(seconds: 30)),
      );
    } catch (error) {
      final failure = _failure(error);
      if (!_closed && epoch == _epoch) {
        _publish(MusicPlaybackState(failure: failure));
      }
      throw MusicPlaybackException(failure);
    } finally {
      _busy = false;
      if (!_closed && epoch == _epoch) {
        _publish(MusicPlaybackState(failure: _state.failure));
      }
    }
  }

  Future<MusicDiscovery> _preflight(
    MusicCatalogSelection source,
    MusicQueueTarget target,
    int epoch, [
    MusicPlaybackIntent? intent,
  ]) async {
    _check(epoch, intent);
    if (!identical(source.accountGeneration, repository.accountGeneration) ||
        source.configEntryId != target.configEntryId ||
        target.registryId == null) {
      throw const MusicPlaybackException(MusicPlaybackFailure.invalidSelection);
    }
    final discovery = await _read(repository.discover);
    _check(epoch, intent);
    final current = discovery.queueTargets
        .where((row) => row.entityId == target.entityId)
        .firstOrNull;
    final entry = discovery.entries
        .where((row) => row.id == source.configEntryId)
        .firstOrNull;
    if (entry == null ||
        !entry.isLoaded ||
        discovery.issues.isNotEmpty ||
        current == null ||
        !_sameTarget(current, target) ||
        !current.available ||
        !current.enabled) {
      throw const MusicPlaybackException(MusicPlaybackFailure.invalidSelection);
    }
    if (!_supportsPlay(discovery.inventory)) {
      throw const MusicPlaybackException(MusicPlaybackFailure.unsupported);
    }
    final List<MusicMediaItem> items;
    if (source.libraryQuery case final query?) {
      items = (await _read(() => repository.library(query))).items;
    } else {
      items = (await _read(() => repository.search(source.searchQuery!))).items;
    }
    _check(epoch, intent);
    final matches = items.where(
      (item) =>
          item.reference.requestValue == source.item.reference.requestValue,
    );
    if (matches.length != 1 || !_sameItem(matches.single, source.item)) {
      throw const MusicPlaybackException(MusicPlaybackFailure.sourceChanged);
    }
    return discovery;
  }

  Future<MusicPlaybackReceipt> execute(MusicPlaybackIntent intent) async {
    if (!identical(intent._owner, _owner) || intent._used) {
      throw const MusicPlaybackException(MusicPlaybackFailure.invalidIntent);
    }
    if (_busy) throw const MusicPlaybackException(MusicPlaybackFailure.busy);
    // Consume before any asynchronous work, including failed preflight.
    intent._used = true;
    final epoch = intent._epoch;
    _check(epoch, intent);
    _busy = true;
    var submitted = false;
    _publish(const MusicPlaybackState(isBusy: true));
    try {
      final before = await _preflight(
        intent.source,
        intent.target,
        epoch,
        intent,
      );
      final query = MusicQueueQuery(
        accountGeneration: repository.accountGeneration,
        configEntryId: intent.target.configEntryId,
        entityId: intent.target.entityId,
      );
      MusicQueueSummary? baseline;
      try {
        baseline = await _read(() => repository.queue(query));
      } catch (_) {
        /* Optional observation baseline. */
      }
      _check(epoch, intent);
      submitted = true;
      var commandCurrent = true;
      try {
        await api
            .play(
              entityId: intent.target.entityId,
              item: intent.item,
              isCurrent: () => commandCurrent && _current(epoch, intent),
            )
            .timeout(const Duration(seconds: 30));
      } finally {
        commandCurrent = false;
      }
      _check(epoch);
      final acceptedAt = now().toUtc();
      var receipt = MusicPlaybackReceipt(
        status: MusicPlaybackReceiptStatus.accepted,
        item: intent.item,
        target: intent.target,
        acceptedAt: acceptedAt,
      );
      _publish(MusicPlaybackState(isBusy: true, receipt: receipt));
      var observed = false;
      try {
        // Read back once; a transport response alone is not playback evidence.
        final after = await _read(repository.discover);
        _check(epoch);
        final queue = await _read(() => repository.queue(query));
        _check(epoch);
        observed = _observed(intent, before, after, baseline, queue);
      } catch (_) {
        _check(epoch);
      }
      receipt = MusicPlaybackReceipt(
        status: observed
            ? MusicPlaybackReceiptStatus.observed
            : MusicPlaybackReceiptStatus.unconfirmed,
        item: intent.item,
        target: intent.target,
        acceptedAt: acceptedAt,
        observedAt: observed ? now().toUtc() : null,
      );
      _publish(MusicPlaybackState(receipt: receipt));
      return receipt;
    } catch (error) {
      final failure = _failure(error);
      final unknown = submitted && !_knownRejection(error);
      if (!_closed && epoch == _epoch) {
        _publish(MusicPlaybackState(failure: failure, outcomeUnknown: unknown));
      }
      throw MusicPlaybackException(failure, outcomeUnknown: unknown);
    } finally {
      _busy = false;
      if (!_closed && epoch != _epoch) _publish(const MusicPlaybackState());
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    repository.close();
    unawaited(_connection?.cancel());
    unawaited(_changes.close());
  }
}

bool _sameTarget(MusicQueueTarget a, MusicQueueTarget b) =>
    a.entityId == b.entityId &&
    a.configEntryId == b.configEntryId &&
    a.registryId == b.registryId &&
    a.deviceId == b.deviceId &&
    a.name == b.name;
bool _sameItem(MusicMediaItem a, MusicMediaItem b) =>
    a.type == b.type &&
    a.reference.requestValue == b.reference.requestValue &&
    a.name == b.name &&
    a.version == b.version &&
    a.album == b.album &&
    a.artists.length == b.artists.length &&
    List.generate(
      a.artists.length,
      (i) => a.artists[i] == b.artists[i],
    ).every((same) => same);
bool _supportsPlay(HaMediaInventory? inventory) {
  final domain = inventory?.services['music_assistant'];
  if (domain is! Map) return false;
  final service = domain['play_media'];
  if (service is! Map) return false;
  final fields = service['fields'];
  if (fields is! Map ||
      fields['media_id'] is! Map ||
      fields['media_type'] is! Map) {
    return false;
  }
  final enqueue = fields['enqueue'];
  if (enqueue is! Map) return false;
  final selector = enqueue['selector'];
  if (selector is! Map || selector['select'] is! Map) return false;
  final options = selector['select']['options'];
  return options is List &&
      options.any(
        (option) =>
            option == 'play' || option is Map && option['value'] == 'play',
      );
}

bool _observed(
  MusicPlaybackIntent intent,
  MusicDiscovery before,
  MusicDiscovery after,
  MusicQueueSummary? baseline,
  MusicQueueSummary queue,
) {
  final target = after.queueTargets
      .where((row) => row.entityId == intent.target.entityId)
      .firstOrNull;
  if (target == null || !_sameTarget(target, intent.target)) return false;
  final previous = before.inventory?.targets
      .where((row) => row.entityId == intent.target.entityId)
      .firstOrNull;
  final current = after.inventory?.targets
      .where((row) => row.entityId == intent.target.entityId)
      .firstOrNull;
  final media = queue.current?.media;
  if (current?.state != 'playing' ||
      !queue.active ||
      media == null ||
      media.type != intent.item.type ||
      media.reference.requestValue != intent.item.reference.requestValue) {
    return false;
  }
  return previous?.state != 'playing' ||
      baseline != null &&
          (baseline.id != queue.id ||
              baseline.current?.id != queue.current?.id ||
              baseline.current?.media?.reference.requestValue !=
                  media.reference.requestValue);
}

MusicPlaybackFailure _failure(Object error) {
  if (error is MusicPlaybackException) return error.failure;
  return switch (classifyMusicFailure(error)) {
    MusicFailure.authentication => MusicPlaybackFailure.authentication,
    MusicFailure.permission => MusicPlaybackFailure.permission,
    MusicFailure.transport => MusicPlaybackFailure.transport,
    MusicFailure.timeout => MusicPlaybackFailure.timeout,
    MusicFailure.unsupported => MusicPlaybackFailure.unsupported,
    MusicFailure.stale => MusicPlaybackFailure.stale,
    MusicFailure.invalidSelection => MusicPlaybackFailure.invalidSelection,
    MusicFailure.invalidResponse ||
    MusicFailure.tooLarge => MusicPlaybackFailure.invalidResponse,
    _ => MusicPlaybackFailure.unavailable,
  };
}

bool _knownRejection(Object error) =>
    error is HaApiException &&
    ({401, 403, 404, 405, 422}.contains(error.statusCode) ||
        {
          'cancelled',
          'unauthorized',
          'forbidden',
          'auth_invalid',
          'not_found',
          'invalid_format',
          'service_validation_error',
        }.contains(error.code));
