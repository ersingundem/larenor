import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../domain/wellbeing_models.dart';
import 'wellbeing_providers.dart';

bool isPublicHaEntity(AsyncValue<Set<String>> privacy, String? entityId) =>
    !privacy.isLoading &&
    !privacy.hasError &&
    privacy.hasValue &&
    (entityId == null || !privacy.requireValue.contains(entityId));

/// Shared household surfaces never expose explicitly private measurements.
/// This is display isolation, not a replacement for HA's account permissions.
final publicHaEntitiesProvider =
    Provider.autoDispose<AsyncValue<Map<String, HaEntity>>>((ref) {
      final privacy = ref.watch(wellbeingPrivateEntityIdsProvider);
      if (privacy.isLoading) return const AsyncLoading();
      if (privacy.hasError || !privacy.hasValue) {
        return AsyncError(
          const WellbeingException(WellbeingFailure.storageFailed),
          StackTrace.empty,
        );
      }
      final states = ref.watch(entitiesProvider);
      if (states.isLoading) return const AsyncLoading();
      if (states.hasError) return AsyncError(states.error!, StackTrace.empty);
      if (!states.hasValue || privacy.requireValue.isEmpty) return states;
      return AsyncData(
        Map.unmodifiable({
          for (final entry in states.requireValue.entries)
            if (!privacy.requireValue.contains(entry.key))
              entry.key: entry.value,
        }),
      );
    });
