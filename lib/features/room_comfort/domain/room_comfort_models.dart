enum ComfortPlanStatus { planned, skipped, blocked }

enum ComfortReason {
  airRefresh,
  temperatureLow,
  temperatureHigh,
  comfortable,
  manualOverride,
  sensorStale,
  smokeDetected,
  freezeRisk,
  rainWindowBlock,
  outdoorAirUnsafe,
}

enum ComfortHvacMode { off, heat, cool, ventilate }

enum ComfortWindowState { closed, open }

enum ComfortOccupancy { occupied, unoccupied, stale }

final class RoomComfortPlan {
  const RoomComfortPlan({
    required this.coreId,
    required this.homeId,
    required this.planId,
    required this.policyId,
    required this.homeRevision,
    required this.policyRevision,
    required this.accountRevision,
    required this.sessionFamilyId,
    required this.generatedAt,
    required this.rooms,
  });

  final String coreId, homeId, planId, policyId, sessionFamilyId;
  final int homeRevision, policyRevision, accountRevision;
  final DateTime generatedAt;
  final List<RoomComfortPlanItem> rooms;

  factory RoomComfortPlan.fromJson(
    Object? raw, {
    required String coreId,
    required String homeId,
    required String accountId,
  }) {
    final value = _object(raw);
    _keys(value, const {
      'schemaVersion',
      'planId',
      'coreId',
      'homeId',
      'homeRevision',
      'policyId',
      'policyRevision',
      'policyHash',
      'actorAccountId',
      'accountRevision',
      'sessionFamilyId',
      'generatedAtMs',
      'inputRevisions',
      'occupancyAdvisory',
      'items',
    });
    if (value['schemaVersion'] != 1 ||
        value['coreId'] != coreId ||
        value['homeId'] != homeId ||
        value['actorAccountId'] != accountId ||
        value['policyHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['policyHash'] as String) ||
        value['inputRevisions'] is! Map) {
      throw const FormatException('invalid_scope');
    }
    final occupancy = _object(value['occupancyAdvisory']);
    final rawItems = value['items'];
    if (rawItems is! List || rawItems.isEmpty || rawItems.length > 32) {
      throw const FormatException('invalid_items');
    }
    final rooms = rawItems
        .map((rawItem) {
          final item = _object(rawItem);
          _keys(item, const {
            'schemaVersion',
            'room',
            'status',
            'reason',
            'hvacMode',
            'windowState',
          });
          final room = _object(item['room']);
          _keys(room, const {
            'schemaVersion',
            'coreId',
            'homeId',
            'roomId',
            'roomRevision',
            'areaId',
            'areaRevision',
            'hvac',
            'window',
          });
          if (item['schemaVersion'] != 1 ||
              room['schemaVersion'] != 1 ||
              room['coreId'] != coreId ||
              room['homeId'] != homeId) {
            throw const FormatException('invalid_room_scope');
          }
          final roomId = _id(room['roomId']);
          return RoomComfortPlanItem(
            roomId: roomId,
            roomRevision: _revision(room['roomRevision']),
            areaId: _id(room['areaId']),
            areaRevision: _revision(room['areaRevision']),
            status: _enum(ComfortPlanStatus.values, item['status']),
            reason: _reason(item['reason']),
            hvacMode: _enum(ComfortHvacMode.values, item['hvacMode']),
            windowState: _enum(ComfortWindowState.values, item['windowState']),
            occupancy: _enum(ComfortOccupancy.values, occupancy[roomId]),
          );
        })
        .toList(growable: false);
    if (occupancy.length != rooms.length ||
        rooms.map((e) => e.roomId).toSet().length != rooms.length) {
      throw const FormatException('invalid_rooms');
    }
    final generated = value['generatedAtMs'];
    if (generated is! int || generated < 0) {
      throw const FormatException('invalid_time');
    }
    return RoomComfortPlan(
      coreId: coreId,
      homeId: homeId,
      planId: _id(value['planId']),
      policyId: _id(value['policyId']),
      homeRevision: _revision(value['homeRevision']),
      policyRevision: _revision(value['policyRevision']),
      accountRevision: _revision(value['accountRevision']),
      sessionFamilyId: _id(value['sessionFamilyId']),
      generatedAt: DateTime.fromMillisecondsSinceEpoch(generated, isUtc: true),
      rooms: List.unmodifiable(rooms),
    );
  }
}

final class RoomComfortPlanItem {
  const RoomComfortPlanItem({
    required this.roomId,
    required this.roomRevision,
    required this.areaId,
    required this.areaRevision,
    required this.status,
    required this.reason,
    required this.hvacMode,
    required this.windowState,
    required this.occupancy,
  });

  final String roomId, areaId;
  final int roomRevision, areaRevision;
  final ComfortPlanStatus status;
  final ComfortReason reason;
  final ComfortHvacMode hvacMode;
  final ComfortWindowState windowState;
  final ComfortOccupancy occupancy;
}

abstract interface class RoomComfortGateway {
  Future<RoomComfortPlan> loadPlan();
  Future<RoomComfortPreview> preview(RoomComfortPlan plan, String requestId);
  Future<RoomComfortReceipt> confirm(RoomComfortPreview preview);
  void retire();
}

final class RoomComfortPreview {
  const RoomComfortPreview({
    required this.id,
    required this.planId,
    required this.policyRevision,
    required this.token,
    required this.expiresAt,
    required this.commandCount,
  });
  final String id, planId, token;
  final int policyRevision, commandCount;
  final DateTime expiresAt;
}

final class RoomComfortReceipt {
  const RoomComfortReceipt({
    required this.requestId,
    required this.planId,
    required this.status,
    required this.commandCount,
  });
  final String requestId, planId, status;
  final int commandCount;
}

Map<String, Object?> _object(Object? raw) {
  if (raw is! Map) throw const FormatException('invalid_object');
  return raw.map((key, value) {
    if (key is! String) throw const FormatException('invalid_key');
    return MapEntry(key, value);
  });
}

void _keys(Map<String, Object?> value, Set<String> keys) {
  if (value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('invalid_shape');
  }
}

String _id(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : throw const FormatException('invalid_id');
int _revision(Object? value) => value is int && value > 0
    ? value
    : throw const FormatException('invalid_revision');
T _enum<T extends Enum>(List<T> values, Object? raw) =>
    values.where((value) => value.name == raw).singleOrNull ??
    (throw const FormatException('invalid_enum'));

ComfortReason _reason(Object? raw) => switch (raw) {
  'air_refresh' => ComfortReason.airRefresh,
  'temperature_low' => ComfortReason.temperatureLow,
  'temperature_high' => ComfortReason.temperatureHigh,
  'comfortable' => ComfortReason.comfortable,
  'manual_override' => ComfortReason.manualOverride,
  'sensor_stale' => ComfortReason.sensorStale,
  'smoke_detected' => ComfortReason.smokeDetected,
  'freeze_risk' => ComfortReason.freezeRisk,
  'rain_window_block' => ComfortReason.rainWindowBlock,
  'outdoor_air_unsafe' => ComfortReason.outdoorAirUnsafe,
  _ => throw const FormatException('invalid_reason'),
};
