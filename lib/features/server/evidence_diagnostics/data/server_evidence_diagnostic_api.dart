import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_evidence_diagnostic_models.dart';

final class ServerEvidenceDiagnosticApi {
  const ServerEvidenceDiagnosticApi(this.api, this.token, this.context);

  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root =>
      '/evidence-diagnostics/${context.coreId}/${context.homeId}';

  Future<EvidenceDiagnosis> diagnoseServices(String requestKey) async {
    final sourceResourceId = await _historySource();
    if (sourceResourceId == null) {
      throw const LarenorServerException('diagnostic_sources_empty');
    }
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/home-assistant-history-diagnoses',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'sourceResourceId': sourceResourceId,
        },
      ),
    );
    if (json.length != 1 || !json.containsKey('diagnosis')) {
      throw const LarenorServerException('invalid_response');
    }
    return EvidenceDiagnosis.fromJson(json['diagnosis']);
  }

  Future<String?> _historySource() async {
    final listed = serverObject(
      await api.request(
        'GET',
        '/home-resources/${context.coreId}/${context.homeId}',
        token: token,
        queryParameters: const {'limit': '100'},
      ),
    );
    final entries = listed['entries'];
    if (entries is! List || entries.length > 100) {
      throw const LarenorServerException('invalid_response');
    }
    for (final raw in entries) {
      final entry = serverObject(raw);
      final ref = serverObject(entry['ref']);
      if (ref['kind'] != 'resource') continue;
      final resourceId = serverText(ref['id'], max: 32);
      try {
        final response = serverObject(
          await api.request(
            'GET',
            '/admin/home-assistant/${context.coreId}/${context.homeId}'
                '/resources/$resourceId/binding',
            token: token,
          ),
        );
        final binding = serverObject(response['binding']);
        serverText(binding['entityId'], max: 256);
        return resourceId;
      } on LarenorServerException catch (error) {
        if (error.code != 'not_found') rethrow;
      }
    }
    return null;
  }

  Future<DiagnosticRepairPreview> preview(
    EvidenceDiagnosis diagnosis,
    String requestKey,
  ) async {
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/diagnoses/${diagnosis.id}/repair-previews',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'expectedDiagnosisRevision': diagnosis.revision,
        },
      ),
    );
    if (json.length != 1 || !json.containsKey('repairPreview')) {
      throw const LarenorServerException('invalid_response');
    }
    final preview = DiagnosticRepairPreview.fromJson(json['repairPreview']);
    if (preview.diagnosisId != diagnosis.id) {
      throw const LarenorServerException('invalid_response');
    }
    return preview;
  }

  static String requestKey(String prefix) {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$prefix:$value';
  }
}
