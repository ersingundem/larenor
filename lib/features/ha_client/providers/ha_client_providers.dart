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

  final client = HaWebSocketClient(
    baseUrl: config.baseUrl,
    token: config.token,
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

/// Live entity state, keyed by `entity_id`. Fetched once via REST, then kept
/// up to date by the `state_changed` WebSocket subscription.
@riverpod
class Entities extends _$Entities {
  StreamSubscription<HaEntity>? _subscription;

  @override
  Future<Map<String, HaEntity>> build() async {
    final rest = ref.watch(haRestClientProvider);
    if (rest == null) return {};

    final states = await rest.getStates();
    final map = {for (final entity in states) entity.entityId: entity};

    final ws = ref.watch(haWebSocketClientProvider);
    unawaited(_subscription?.cancel());
    _subscription = ws?.entityUpdates.listen(_onUpdate);
    ref.onDispose(() => _subscription?.cancel());

    return map;
  }

  void _onUpdate(HaEntity entity) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData({...current, entity.entityId: entity});
  }

  Future<void> toggle(HaEntity entity) async {
    final rest = ref.read(haRestClientProvider);
    if (rest == null) return;
    final service = entity.isOn ? 'turn_off' : 'turn_on';
    await rest.callService(entity.domain, service, entityId: entity.entityId);
  }
}
