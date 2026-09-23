import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
import '../domain/capability_evidence_models.dart';

final class CapabilityEvidenceApi {
  const CapabilityEvidenceApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;

  Future<List<CapabilityEvidenceRecord>> list() async {
    final root =
        '/capability-evidence/${context.coreId}/${context.homeId}/records';
    final records = <CapabilityEvidenceRecord>[];
    String? after;
    for (var page = 0; page < 6; page++) {
      final response = await api.request(
        'GET',
        root,
        token: token,
        queryParameters: {'limit': '50', 'after': ?after},
      );
      const responseKeys = {'schemaVersion', 'scope', 'records', 'nextAfter'};
      if (response is! Map<String, dynamic> ||
          response.keys.toSet().difference(responseKeys).isNotEmpty ||
          responseKeys.difference(response.keys.toSet()).isNotEmpty ||
          response['schemaVersion'] != 1 ||
          response['scope'] is! Map ||
          response['records'] is! List) {
        throw const LarenorServerException('invalid_response');
      }
      final scope = response['scope'];
      if (scope['schemaVersion'] != 1 ||
          scope['coreId'] != context.coreId ||
          scope['homeId'] != context.homeId ||
          scope.keys.length != 3) {
        throw const LarenorServerException('invalid_response');
      }
      try {
        final batch = (response['records'] as List)
            .map(CapabilityEvidenceRecord.fromJson)
            .toList();
        var previousId = records.lastOrNull?.id;
        final strictlyIncreasing = batch.every((record) {
          final accepted =
              previousId == null || record.id.compareTo(previousId!) > 0;
          previousId = record.id;
          return accepted;
        });
        if (batch.length > 50 || !strictlyIncreasing) {
          throw const FormatException('Invalid evidence');
        }
        records.addAll(batch);
        if (records.length > 256) {
          throw const FormatException('Evidence limit exceeded');
        }
        final cursor = response['nextAfter'];
        if (cursor == null) return List.unmodifiable(records);
        if (cursor is! String ||
            batch.isEmpty ||
            cursor != batch.last.id ||
            records.length >= 256) {
          throw const FormatException('Invalid cursor');
        }
        after = cursor;
      } on FormatException {
        throw const LarenorServerException('invalid_response');
      }
    }
    throw const LarenorServerException('invalid_response');
  }
}
