import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../auth/providers/auth_providers.dart';
import '../../health/providers/ha_actions.dart';
import '../data/models/ha_entity.dart';
import '../data/rest_client.dart';
import '../data/ws_client.dart';
import 'ha_health_bindings.dart';

part 'ha_client_providers.g.dart';

@riverpod
HaRestClient? haRestClient(Ref ref) {
  final config = ref.watch(connectionConfigProvider).value;
  final health = ref.watch(haHealthSessionProvider);
  if (config == null) return null;

  final client = HaRestClient(
    baseUrl: config.baseUrl,
    token: config.token,
    observer: health.observeTransport,
    healthSession: health,
  );
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
HaWebSocketClient? haWebSocketClient(Ref ref) {
  final config = ref.watch(connectionConfigProvider).value;
  final health = ref.watch(haHealthSessionProvider);
  if (config == null) return null;

  final client = HaWebSocketClient(
    baseUrl: config.baseUrl,
    token: config.token,
    connectionObserver: (event) => observeHaConnection(health, event),
  )..connect();
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
Stream<HaConnectionStatus> haConnectionStatus(Ref ref) {
  final client = ref.watch(haWebSocketClientProvider);
  if (client == null) return Stream.value(HaConnectionStatus.disconnected);
  return client.status;
}

/// Live entity state, keyed by `entity_id`. Buffer WebSocket events while
/// fetching a complete snapshot, and resync after every new subscription.
@riverpod
class Entities extends _$Entities {
  @override
  Future<Map<String, HaEntity>> build() async {
    final rest = ref.watch(haRestClientProvider);
    final ws = ref.watch(haWebSocketClientProvider);
    final health = rest?.healthSession;
    if (rest == null) return {};

    final pending = <String, HaEntityChange>{};
    var active = true;
    var snapshotReady = false;
    Timer? updateBatch;

    void applyPending() {
      if (!active || !snapshotReady || pending.isEmpty) return;
      final current = state.value;
      if (current == null) return;
      final next = {...current};
      final changed = _mergeUpdates(next, pending);
      pending.clear();
      if (changed) state = AsyncData(next);
    }

    // Subscribe before starting REST: an event received during that request
    // must not be lost or overwritten by an older HTTP snapshot.
    final updates = ws?.entityChanges.listen((change) {
      if (!active) return;
      final previousTime = pending[change.entityId]?.time;
      if (previousTime != null &&
          change.time != null &&
          change.time!.isBefore(previousTime)) {
        return;
      }
      pending[change.entityId] = change;
      // Drain the current event-loop burst before copying the full map.
      // A coalesced HA frame can contain thousands of entity changes; only
      // the newest change per entity matters to the next rendered frame.
      updateBatch ??= Timer(Duration.zero, () {
        updateBatch = null;
        applyPending();
      });
    });
    final connection = ws?.status.skip(1).listen((status) {
      if (active && status == HaConnectionStatus.connected) {
        // "connected" means subscribe_events was acknowledged. A snapshot
        // now also covers all changes made while the socket was unavailable.
        ref.invalidateSelf();
      }
    });
    final stopListening = listenSelf((previous, next) {
      if (!snapshotReady && next is AsyncData<Map<String, HaEntity>>) {
        snapshotReady = true;
        // Also cover events delivered between build returning and Riverpod
        // publishing its result, without a reentrant state notification.
        scheduleMicrotask(applyPending);
      }
    });
    ref.onDispose(() {
      active = false;
      updateBatch?.cancel();
      unawaited(updates?.cancel());
      unawaited(connection?.cancel());
      stopListening();
    });

    final List<HaEntity> states;
    try {
      states = await rest.getStates();
      if (active) health?.readSucceeded(synchronizesLiveSnapshot: true);
    } catch (error) {
      if (active) health?.failed(classifyHaReadFailure(error));
      rethrow;
    }
    final map = {for (final entity in states) entity.entityId: entity};
    _mergeUpdates(map, pending);
    pending.clear();
    return map;
  }

  bool _mergeUpdates(
    Map<String, HaEntity> snapshot,
    Map<String, HaEntityChange> updates,
  ) {
    var changed = false;
    for (final entry in updates.entries) {
      final snapshotTime = snapshot[entry.key]?.lastUpdated;
      final updateTime = entry.value.time;
      if (snapshotTime != null &&
          updateTime != null &&
          updateTime.isBefore(snapshotTime)) {
        continue;
      }
      final entity = entry.value.entity;
      if (entity == null) {
        changed = snapshot.remove(entry.key) != null || changed;
      } else if (snapshot[entry.key] != entity) {
        snapshot[entry.key] = entity;
        changed = true;
      }
    }
    return changed;
  }

  Future<void> toggle(HaEntity entity) async {
    final service = entity.isOn ? 'turn_off' : 'turn_on';
    await ref
        .read(haActionExecutorProvider)
        .execute(
          domain: entity.domain,
          service: service,
          entityId: entity.entityId,
        );
  }
}
