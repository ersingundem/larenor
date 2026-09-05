import 'dart:async';

import '../../admin/data/admin_client.dart';
import '../../ha_client/data/ha_api_exception.dart';
import '../../admin/data/models/ha_area.dart';
import '../../admin/data/models/ha_device.dart';
import '../../admin/data/models/ha_registry_entry.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../domain/ha_area_binding.dart';
import '../domain/room_area_sync.dart';

/// A read-only boundary injectable without device/network access in tests.
abstract class RoomAreaSyncReader {
  Future<AreaSyncSnapshot> read();
}

class HaRoomAreaSyncReader implements RoomAreaSyncReader {
  HaRoomAreaSyncReader({
    required this.client,
    required this.serverUrl,
    required this.entities,
    required this.isCurrent,
  });
  final HaAdminClient client;
  final String serverUrl;
  final Future<Map<String, HaEntity>> Function() entities;
  final bool Function() isCurrent;

  @override
  Future<AreaSyncSnapshot> read() async {
    if (!isCurrent()) throw const RoomAreaSyncException('account_changed');
    try {
      // Official HA 2026.8.3 config registries list operations; no mutation or
      // assumption that a failed/forbidden list is an empty registry.
      final results = await Future.wait<Object>([
        client.listAreas(),
        client.listDevices(),
        client.listEntityRegistry(),
        entities(),
      ], eagerError: true).timeout(const Duration(seconds: 20));
      if (!isCurrent()) throw const RoomAreaSyncException('account_changed');
      return AreaSyncSnapshot(
        serverUrl: normalizedAreaServerUrl(serverUrl),
        areas: results[0] as List<HaArea>,
        devices: results[1] as List<HaDevice>,
        registry: results[2] as List<HaRegistryEntry>,
        entities: results[3] as Map<String, HaEntity>,
      );
    } on RoomAreaSyncException {
      rethrow;
    } on HaApiException catch (error) {
      if (!isCurrent()) throw const RoomAreaSyncException('account_changed');
      final permission =
          error.statusCode == 401 ||
          error.statusCode == 403 ||
          {'unauthorized', 'forbidden', 'auth_invalid'}.contains(error.code);
      throw RoomAreaSyncException(permission ? 'permission' : 'unavailable');
    } on TimeoutException {
      throw const RoomAreaSyncException('unavailable');
    } on FormatException {
      throw const RoomAreaSyncException('invalid_data');
    } on TypeError {
      throw const RoomAreaSyncException('invalid_data');
    } catch (_) {
      throw const RoomAreaSyncException('unavailable');
    }
  }
}

class RoomAreaSyncException implements Exception {
  const RoomAreaSyncException(this.code);
  final String code;
  @override
  String toString() => 'Room area synchronization could not be completed';
}
