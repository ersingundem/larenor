import '../../ha_client/data/models/ha_entity.dart';

enum MaintenanceScope { selected, all }

enum MaintenanceKind { problem, unavailable, lowBattery, updateAvailable }

class MaintenanceItem {
  MaintenanceItem({
    required this.entityId,
    required this.name,
    required Set<MaintenanceKind> kinds,
    this.batteryPercent,
  }) : kinds = Set.unmodifiable(kinds);
  final String entityId;
  final String name;
  final Set<MaintenanceKind> kinds;
  final double? batteryPercent;
}

class MaintenanceSnapshot {
  MaintenanceSnapshot({
    required this.scope,
    List<MaintenanceItem> items = const [],
    this.checkedEntities = 0,
    this.isLoading = false,
    this.readFailed = false,
  }) : items = List.unmodifiable(items);
  final MaintenanceScope scope;
  final List<MaintenanceItem> items;
  final int checkedEntities;
  final bool isLoading;
  final bool readFailed;
}

/// Device maintenance only. There is no personal-health inference and no
/// action endpoint; items navigate to the normal entity detail screen.
MaintenanceSnapshot buildMaintenanceSnapshot(
  Map<String, HaEntity> entities, {
  required MaintenanceScope scope,
  Set<String> selectedIds = const {},
}) {
  final candidates = scope == MaintenanceScope.all
      ? entities.values
      : selectedIds.map((id) => entities[id]).whereType<HaEntity>();
  final items = <MaintenanceItem>[];
  var checked = 0;
  for (final entity in candidates) {
    checked++;
    final kinds = <MaintenanceKind>{};
    double? battery;
    final deviceClass = entity.attributes['device_class'];
    if (entity.state == 'unavailable') kinds.add(MaintenanceKind.unavailable);
    if (entity.domain == 'binary_sensor' && entity.state == 'on') {
      if (deviceClass == 'battery') kinds.add(MaintenanceKind.lowBattery);
      if (deviceClass == 'problem') kinds.add(MaintenanceKind.problem);
    }
    if (entity.domain == 'sensor' &&
        deviceClass == 'battery' &&
        entity.attributes['unit_of_measurement'] == '%') {
      final value = double.tryParse(entity.state);
      if (value != null && value.isFinite && value >= 0 && value <= 100) {
        battery = value;
        if (value <= 20) kinds.add(MaintenanceKind.lowBattery);
      }
    }
    if (entity.domain == 'update' && entity.state == 'on') {
      kinds.add(MaintenanceKind.updateAvailable);
    }
    if (kinds.isEmpty) continue;
    final name = entity.attributes['friendly_name'];
    items.add(
      MaintenanceItem(
        entityId: entity.entityId,
        name: name is String && name.length <= 512 ? name : entity.entityId,
        kinds: kinds,
        batteryPercent: battery,
      ),
    );
  }
  int priority(MaintenanceItem item) =>
      item.kinds.map((kind) => kind.index).reduce((a, b) => a < b ? a : b);
  items.sort((a, b) {
    final rank = priority(a).compareTo(priority(b));
    return rank != 0 ? rank : a.entityId.compareTo(b.entityId);
  });
  return MaintenanceSnapshot(
    scope: scope,
    items: items,
    checkedEntities: checked,
  );
}
