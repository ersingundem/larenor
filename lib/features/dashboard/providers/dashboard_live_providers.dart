import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../domain/home_domains.dart';
import 'dashboard_providers.dart';

/// Only saved, visible accessories participate in the dashboard structure.
/// Diagnostic entities and state/attribute updates do not rebuild the room
/// grids, navigation, or service widgets.
final dashboardVisibleIdsProvider = Provider.autoDispose<Set<String>>((ref) {
  final layout = ref.watch(dashboardLayoutProvider).value;
  if (layout == null) return const {};
  final hidden = layout.hiddenEntityIds.toSet();
  return {
    ...layout.favoriteEntityIds,
    for (final room in layout.rooms) ...room.entityIds,
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
            states.value?[id] ?? HaEntity(entityId: id, state: 'unavailable'),
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
        final entity = states.value?[id];
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
  return ref.watch(entitiesProvider.select((states) => states.value?[id])) ??
      HaEntity(entityId: id, state: 'unavailable');
});
