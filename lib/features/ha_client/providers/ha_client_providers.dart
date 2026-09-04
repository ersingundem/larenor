import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../auth/providers/auth_providers.dart';
import '../data/models/ha_entity.dart';
import '../data/rest_client.dart';
import '../data/ws_client.dart';

part 'ha_client_providers.g.dart';

@riverpod
HaRestClient? haRestClient(Ref ref) {
  final config = ref.watch(connectionConfigProvider).value;
  if (config == null) return null;

  final client = HaRestClient(baseUrl: config.baseUrl, token: config.token);
  ref.onDispose(client.dispose);
  return client;
}

@riverpod
HaWebSocketClient? haWebSocketClient(Ref ref) {
  final config = ref.watch(connectionConfigProvider).value;
  if (config == null) return null;

  final client = HaWebSocketClient(baseUrl: config.baseUrl, token: config.token)
    ..connect();
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
    if (rest == null) return {};

    final pending = <String, HaEntityChange>{};
    var active = true;
    var snapshotReady = false;

    void applyPending() {
      if (!active || !snapshotReady || pending.isEmpty) return;
      final current = state.value;
      if (current == null) return;
      final next = {...current};
      _mergeUpdates(next, pending);
      pending.clear();
      state = AsyncData(next);
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
      applyPending();
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
      unawaited(updates?.cancel());
      unawaited(connection?.cancel());
      stopListening();
    });

    final states = await rest.getStates();
    final map = {for (final entity in states) entity.entityId: entity};
    _mergeUpdates(map, pending);
    pending.clear();
    return map;
  }

  void _mergeUpdates(
    Map<String, HaEntity> snapshot,
    Map<String, HaEntityChange> updates,
  ) {
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
        snapshot.remove(entry.key);
      } else {
        snapshot[entry.key] = entity;
      }
    }
  }

  Future<void> toggle(HaEntity entity) async {
    final rest = ref.read(haRestClientProvider);
    if (rest == null) return;
    final service = entity.isOn ? 'turn_off' : 'turn_on';
    await rest.callService(entity.domain, service, entityId: entity.entityId);
  }
}
