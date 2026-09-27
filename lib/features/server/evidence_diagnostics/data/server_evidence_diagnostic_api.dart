import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../services/data/server_services_api.dart';
import '../../services/domain/server_service_models.dart';
import '../domain/server_evidence_diagnostic_models.dart';

final class ServerEvidenceDiagnosticApi {
  const ServerEvidenceDiagnosticApi(this.api, this.token, this.context);

  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root =>
      '/evidence-diagnostics/${context.coreId}/${context.homeId}';

  Future<EvidenceDiagnosis> diagnoseServices(String requestKey) async {
    final serviceApi = ServerServicesApi(api, token);
    final configured = (await serviceApi.list()).take(32).toList();
    if (configured.isEmpty) {
      throw const LarenorServerException('diagnostic_sources_empty');
    }
    final checked = <ServerService>[];
    for (final service in configured) {
      checked.add(await serviceApi.check(service));
    }
    final sources = [
      for (final service in checked)
        {
          'sourceId': 'service:${service.id}',
          'sourceType': 'health',
          'revision': service.revision,
          'capturedAtMs': _capturedAt(service),
          'state': _state(service.verification.state),
          'detail': '${service.kind.wireName}:${service.name}',
          'measurements': const [],
          'events': const [],
        },
    ];
    final json = serverObject(
      await api.request(
        'POST',
        '$_root/diagnoses',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': requestKey,
          'sources': sources,
        },
      ),
    );
    if (json.length != 1 || !json.containsKey('diagnosis')) {
      throw const LarenorServerException('invalid_response');
    }
    return EvidenceDiagnosis.fromJson(json['diagnosis']);
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

  static String _state(ServerServiceVerificationState state) => switch (state) {
    ServerServiceVerificationState.authenticated ||
    ServerServiceVerificationState.reachable => 'healthy',
    ServerServiceVerificationState.unavailable => 'unavailable',
    ServerServiceVerificationState.unauthorized => 'critical',
    ServerServiceVerificationState.unsupported ||
    ServerServiceVerificationState.never => 'unknown',
  };

  static int _capturedAt(ServerService service) {
    final value = service.verification.checkedAt;
    if (value == null) {
      throw const LarenorServerException('invalid_response');
    }
    return value.millisecondsSinceEpoch;
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
