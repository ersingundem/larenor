import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../wellbeing/providers/wellbeing_providers.dart';
import '../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../domain/home_domains.dart';
import '../domain/ha_area_binding.dart';
import 'dashboard_providers.dart';

/// Only saved, visible accessories participate in the dashboard structure.
/// Diagnostic entities and state/attribute updates do not rebuild the room
/// grids, navigation, or service widgets.
final dashboardVisibleIdsProvider = Provider.autoDispose<Set<String>>((ref) {
  final privacy = ref.watch(wellbeingPrivateEntityIdsProvider);
  if (privacy.isLoading || privacy.hasError || !privacy.hasValue) {
    return const {};
  }
  final layout = ref.watch(dashboardLayoutProvider).value;
  if (layout == null) return const {};
  String? currentServer;
  if (layout.rooms.any((room) => room.areaBinding != null)) {
    final config = ref.watch(connectionConfigProvider);
    if (!config.isLoading && !config.hasError && config.value != null) {
      try {
        currentServer = normalizedAreaServerUrl(config.value!.baseUrl);
      } on FormatException {
        /* Invalid saved URL cannot match a binding. */
      }
    }
  }
  final hidden = {...layout.hiddenEntityIds, ...privacy.requireValue};
  return {
    ...layout.favoriteEntityIds,
    for (final room in layout.rooms)
      if (room.areaBinding == null ||
          room.areaBinding!.serverUrl == currentServer)
        ...room.entityIds,
  }..removeAll(hidden);
});

class DashboardCategories {
  DashboardCategories(this.byId);
  final Map<String, HomeCategory> byId;

  @override
  bool operator ==(Object other) =>
      other is DashboardCategories && mapEquals(byId, other.byId);

  @override
  int get hashCode => Object.hashAllUnordered(
    byId.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

final dashboardCategoriesProvider = Provider.autoDispose<DashboardCategories>((
  ref,
) {
  final ids = ref.watch(dashboardVisibleIdsProvider);
  return ref.watch(
    entitiesProvider.select(
      (states) => DashboardCategories({
        for (final id in ids)
          id: homeCategoryForEntity(
            _visibleEntities(states)?[id] ??
                HaEntity(entityId: id, state: 'unavailable'),
          ),
      }),
    ),
  );
});

typedef DashboardSummary = ({int accessories, int lightsOn, int unavailable});

final dashboardSummaryProvider = Provider.autoDispose<DashboardSummary>((ref) {
  final ids = ref.watch(dashboardVisibleIdsProvider);
  return ref.watch(
    entitiesProvider.select((states) {
      var lightsOn = 0;
      var unavailable = 0;
      for (final id in ids) {
        final entity = _visibleEntities(states)?[id];
        if (entity?.domain == 'light' && entity!.isOn) lightsOn++;
        if (entity == null ||
            entity.state == 'unavailable' ||
            entity.state == 'unknown') {
          unavailable++;
        }
      }
      return (
        accessories: ids.length,
        lightsOn: lightsOn,
        unavailable: unavailable,
      );
    }),
  );
});

/// Each mounted accessory subscribes only to its own state. Offscreen tiles
/// are lazily built by SliverGrid and have no subscription until mounted.
final dashboardEntityProvider = Provider.autoDispose.family<HaEntity, String>((
  ref,
  id,
) {
  if (!isPublicHaEntity(ref.watch(wellbeingPrivateEntityIdsProvider), id)) {
    return HaEntity(entityId: id, state: 'unavailable');
  }
  return ref.watch(
        entitiesProvider.select((states) => _visibleEntities(states)?[id]),
      ) ??
      HaEntity(entityId: id, state: 'unavailable');
});

// Riverpod can retain old values while another account is loading or after a
// failed replacement. A disconnected socket with an unchanged AsyncData map
// still shows the same account's last snapshot; replacement states never do.
Map<String, HaEntity>? _visibleEntities(
  AsyncValue<Map<String, HaEntity>> states,
) => states.isLoading || states.hasError ? null : states.value;
