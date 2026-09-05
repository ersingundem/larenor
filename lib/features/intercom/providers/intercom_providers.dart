import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../auth/data/ha_connection_config.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../ha_tools/presentation/ha_actions_screen.dart';
import '../../health/data/integration_health.dart';
import '../../health/providers/ha_actions.dart';
import '../../health/providers/health_providers.dart';
import '../data/door_station_store.dart';
import '../domain/door_station.dart';

final doorStationStoreProvider = Provider(
  (ref) => DoorStationStore(access: ref.watch(directHomeAccessProvider)),
);
final doorStationsProvider = FutureProvider.autoDispose<List<DoorStation>>((
  ref,
) async {
  final access = ref.watch(directHomeAccessProvider);
  access.check();
  final result = await ref.watch(doorStationStoreProvider).read();
  access.check();
  if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
  return result;
});

/// Injectable clock for deterministic expiry tests, evaluated at dispatch too.
final doorReleaseClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

enum DoorReleaseBlock {
  notCommissioned,
  differentServer,
  staleState,
  unavailable,
  noActiveCall,
  unsupported,
  mappingChanged,
  intentExpired,
}

class DoorReleaseException implements Exception {
  const DoorReleaseException(this.reason);
  final DoorReleaseBlock reason;
  @override
  String toString() => 'Door release requires verification.';
}

/// A healthy REST request cannot establish a live door/call observation.
bool doorReleaseHasLiveState(IntegrationHealth health, DateTime now) {
  final contact = health.lastLiveContact;
  return health.configured &&
      health.failure == null &&
      !health.connecting &&
      health.retryAttempt == 0 &&
      health.lastSuccessfulRead != null &&
      health.liveUpdates &&
      health.liveSnapshotSynchronized &&
      contact != null &&
      !now.isBefore(contact) &&
      now.difference(contact) <= health.liveFreshness;
}

DoorReleaseBlock? doorReleaseBlock({
  required DoorStation station,
  required String? serverUrl,
  required bool fresh,
  required Map<String, HaEntity> entities,
  required bool serviceAvailable,
}) {
  // Also validate callers that constructed a station without decoding storage.
  try {
    DoorStation.fromJson(station.toJson());
  } catch (_) {
    return DoorReleaseBlock.unsupported;
  }
  if (!station.unlockEnabled || station.unlockEntityId == null) {
    return DoorReleaseBlock.notCommissioned;
  }
  if (station.serverUrl != serverUrl) return DoorReleaseBlock.differentServer;
  if (!fresh) return DoorReleaseBlock.staleState;
  final control = entities[station.unlockEntityId];
  if (control == null ||
      control.entityId != station.unlockEntityId ||
      control.state == 'unavailable' ||
      (control.domain == 'lock' &&
          !{'locked', 'unlocked'}.contains(control.state))) {
    return DoorReleaseBlock.unavailable;
  }
  // HA button state is a last-pressed timestamp, or unknown before first use.
  // It is not an on/off availability state.
  if (station.requiresActiveCall &&
      entities[station.callActiveEntityId]?.state != 'on') {
    return DoorReleaseBlock.noActiveCall;
  }
  if (!serviceAvailable) return DoorReleaseBlock.unsupported;
  return null;
}

String doorReleaseService(DoorStation station) =>
    station.unlockEntityId?.startsWith('lock.') == true ? 'unlock' : 'press';

DoorReleaseBlock? _currentBlock(
  Ref ref,
  DoorStation station, {
  Map<String, HaEntityChange> observations = const {},
}) {
  final config = ref.read(connectionConfigProvider);
  final mappings = ref.read(doorStationsProvider);
  if (mappings.isLoading ||
      mappings.hasError ||
      !(mappings.value?.contains(station) ?? false)) {
    return DoorReleaseBlock.mappingChanged;
  }
  final states = ref.read(entitiesProvider);
  final catalog = ref.read(haActionsProvider);
  final health = ref.read(healthMonitorProvider).read(IntegrationId.ha);
  final domain = station.unlockEntityId?.split('.').first;
  final entities = {...?states.value};
  for (final change in observations.values) {
    final snapshotTime = entities[change.entityId]?.lastUpdated;
    if (snapshotTime != null &&
        change.time != null &&
        change.time!.isBefore(snapshotTime)) {
      continue;
    }
    if (change.entity case final HaEntity entity) {
      entities[change.entityId] = entity;
    } else {
      entities.remove(change.entityId);
    }
  }
  return doorReleaseBlock(
    station: station,
    serverUrl: config.isLoading || config.hasError
        ? null
        : config.value?.baseUrl,
    fresh:
        !states.isLoading &&
        !states.hasError &&
        states.hasValue &&
        ref.read(haWebSocketClientProvider) != null &&
        doorReleaseHasLiveState(health, ref.read(doorReleaseClockProvider)()),
    entities: entities,
    serviceAvailable:
        !catalog.isLoading &&
        !catalog.hasError &&
        (catalog.value?.any(
              (action) =>
                  action.domain == domain &&
                  action.service == doorReleaseService(station),
            ) ??
            false),
  );
}

final doorReleaseBlockProvider = Provider.autoDispose
    .family<DoorReleaseBlock?, DoorStation>((ref, station) {
      ref.watch(connectionConfigProvider);
      ref.watch(doorStationsProvider);
      ref.watch(entitiesProvider);
      ref.watch(haActionsProvider);
      ref.watch(haWebSocketClientProvider);
      ref.watch(integrationHealthProvider(IntegrationId.ha));
      ref.watch(healthClockProvider);
      return _currentBlock(ref, station);
    });

/// Opaque, short-lived and single-use confirmation context. It is never saved.
class DoorReleaseIntent {
  DoorReleaseIntent._({
    required this.station,
    required this._owner,
    required this._connection,
    required this._createdAt,
    required this._releaseKeepAlive,
  });
  final DoorStation station;
  final _DoorReleaseCoordinator _owner;
  final HaConnectionConfig _connection;
  final DateTime _createdAt;
  final void Function() _releaseKeepAlive;
  Timer? _expiry;
  DoorReleaseBlock? _invalid;
  bool _used = false;

  void _invalidate(DoorReleaseBlock reason) {
    _invalid ??= reason;
    _expiry?.cancel();
    _releaseKeepAlive();
  }
}

final _doorReleaseCoordinatorProvider = Provider.autoDispose((ref) {
  final coordinator = _DoorReleaseCoordinator(ref);
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// Invoke before opening confirmation. Each call creates a new intent.
final doorReleaseIntentProvider = Provider.autoDispose(
  (ref) => ref.watch(_doorReleaseCoordinatorProvider).prepare,
);

/// Invoke only after confirmation; validates current state before one dispatch.
final doorReleaseActionProvider = Provider.autoDispose(
  (ref) => ref.watch(_doorReleaseCoordinatorProvider).release,
);

class _DoorReleaseCoordinator {
  _DoorReleaseCoordinator(this.ref) {
    ref.listen(connectionConfigProvider, (previous, next) {
      if (!identical(previous?.value, next.value) ||
          next.isLoading ||
          next.hasError) {
        _observations.clear();
        _invalidateAll(DoorReleaseBlock.intentExpired);
      }
    });
    ref.listen(doorStationsProvider, (_, next) {
      final mappedIds = {
        for (final station in next.value ?? <DoorStation>[]) ...[
          station.unlockEntityId,
          station.callActiveEntityId,
        ],
      };
      _observations.removeWhere((id, _) => !mappedIds.contains(id));
      for (final intent in [..._intents]) {
        if (next.isLoading ||
            next.hasError ||
            !(next.value?.contains(intent.station) ?? false)) {
          _invalidate(intent, DoorReleaseBlock.mappingChanged);
        }
      }
    });
    ref.listen(entitiesProvider, (_, next) {
      if (next.isLoading || next.hasError) {
        _invalidateAll(DoorReleaseBlock.staleState);
      }
    });
    ref.listen(haWebSocketClientProvider, (_, next) {
      _invalidateAll(DoorReleaseBlock.staleState);
      _observations.clear();
      unawaited(_updates?.cancel());
      unawaited(_connection?.cancel());
      _updates = next?.entityChanges.listen(_observe);
      _connection = next?.status.listen((status) {
        if (status != HaConnectionStatus.connected) {
          _invalidateAll(DoorReleaseBlock.staleState);
        }
      });
    }, fireImmediately: true);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          _invalidateAll(DoorReleaseBlock.intentExpired);
        }
      },
    );
  }

  final Ref ref;
  final _intents = <DoorReleaseIntent>{};
  // Only configured control/call entities are retained, bounded by 16 stations.
  final _observations = <String, HaEntityChange>{};
  StreamSubscription<HaEntityChange>? _updates;
  StreamSubscription<HaConnectionStatus>? _connection;
  late final AppLifecycleListener _lifecycle;
  bool _disposed = false;
  static const _lifetime = Duration(seconds: 30);

  void _observe(HaEntityChange change) {
    final stations = ref.read(doorStationsProvider).value ?? const [];
    if (!stations.any(
      (station) =>
          station.unlockEntityId == change.entityId ||
          station.callActiveEntityId == change.entityId,
    )) {
      return;
    }
    final previous = _observations[change.entityId];
    if (previous?.time != null &&
        change.time != null &&
        change.time!.isBefore(previous!.time!)) {
      return;
    }
    _observations[change.entityId] = change;
    // Do not wait for the batched dashboard map to catch up: an ended/replaced
    // call or a changed control invalidates the already visible confirmation.
    for (final intent in [..._intents]) {
      if (intent.station.unlockEntityId == change.entityId ||
          intent.station.callActiveEntityId == change.entityId) {
        _invalidate(intent, DoorReleaseBlock.intentExpired);
      }
    }
  }

  DoorReleaseIntent prepare(DoorStation station) {
    if (_disposed || !_foreground) {
      throw const DoorReleaseException(DoorReleaseBlock.intentExpired);
    }
    final block = _currentBlock(ref, station, observations: _observations);
    if (block != null) throw DoorReleaseException(block);
    // Only one visible confirmation is needed; old requests cannot accumulate.
    _invalidateAll(DoorReleaseBlock.intentExpired);
    final keepAlive = ref.keepAlive();
    final intent = DoorReleaseIntent._(
      station: station,
      owner: this,
      connection: ref.read(connectionConfigProvider).value!,
      createdAt: ref.read(doorReleaseClockProvider)(),
      releaseKeepAlive: keepAlive.close,
    );
    _intents.add(intent);
    intent._expiry = Timer(
      _lifetime,
      () => _invalidate(intent, DoorReleaseBlock.intentExpired),
    );
    return intent;
  }

  Future<void> release(DoorReleaseIntent intent, {String? code}) async {
    if (_disposed || !_foreground) {
      throw const DoorReleaseException(DoorReleaseBlock.intentExpired);
    }
    final now = ref.read(doorReleaseClockProvider)();
    if (intent._owner != this ||
        intent._used ||
        intent._invalid != null ||
        now.isBefore(intent._createdAt) ||
        now.difference(intent._createdAt) >= _lifetime ||
        !identical(
          ref.read(connectionConfigProvider).value,
          intent._connection,
        )) {
      throw DoorReleaseException(
        intent._invalid ?? DoorReleaseBlock.intentExpired,
      );
    }
    final block = _currentBlock(
      ref,
      intent.station,
      observations: _observations,
    );
    if (block != null) {
      _invalidate(intent, block);
      throw DoorReleaseException(block);
    }
    final entityId = intent.station.unlockEntityId!;
    final isLock = entityId.startsWith('lock.');
    final control =
        _observations[entityId]?.entity ??
        ref.read(entitiesProvider).value?[entityId];
    if ((code != null &&
            (!isLock ||
                code.length > 128 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(code))) ||
        (isLock &&
            control?.attributes['code_format'] != null &&
            (code == null || code.isEmpty))) {
      throw const DoorReleaseException(DoorReleaseBlock.unsupported);
    }
    intent._used = true;
    intent._expiry?.cancel();
    try {
      // No await between the final checks and the executor's one send.
      await ref
          .read(haActionExecutorProvider)
          .execute(
            domain: isLock ? 'lock' : 'button',
            service: doorReleaseService(intent.station),
            entityId: entityId,
            serviceData: code == null ? null : {'code': code},
          );
    } finally {
      _invalidate(intent, DoorReleaseBlock.intentExpired);
    }
  }

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _invalidate(DoorReleaseIntent intent, DoorReleaseBlock reason) {
    intent._invalidate(reason);
    _intents.remove(intent);
  }

  void _invalidateAll(DoorReleaseBlock reason) {
    for (final intent in [..._intents]) {
      _invalidate(intent, reason);
    }
  }

  void dispose() {
    _disposed = true;
    _invalidateAll(DoorReleaseBlock.intentExpired);
    _lifecycle.dispose();
    unawaited(_updates?.cancel());
    unawaited(_connection?.cancel());
  }
}
