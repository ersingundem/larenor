import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ha_client/providers/ha_client_providers.dart';
import '../data/entity_history.dart';

/// One read per observed entity/account. Old clients cannot publish into a
/// replacement generation. The tile hides retained data during reload/error.
final entityHistoryProvider = FutureProvider.autoDispose
    .family<EntityHistorySeries?, String>((ref, entityId) async {
      if (!RegExp(r'^[a-z_]+\.[a-z0-9_]+$').hasMatch(entityId)) {
        throw const FormatException('Invalid history entity');
      }
      final client = ref.watch(haRestClientProvider);
      if (client == null) return null;
      final end = DateTime.now().toUtc();
      final start = end.subtract(const Duration(hours: 24));
      final result = await client.getHistory(
        startTime: start,
        endTime: end,
        entityIds: [entityId],
        noAttributes: true,
        significantChangesOnly: false,
      );
      if (!ref.mounted) return null;
      return parseEntityHistory(
        result,
        entityId: entityId,
        start: start,
        end: end,
      );
    }, retry: (_, _) => null);
