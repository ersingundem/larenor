import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/core_audit_models.dart';

final class CoreAuditApi {
  const CoreAuditApi(this._transport, this._token, this.context);

  final LarenorServerApi _transport;
  final String _token;
  final ServerContext context;

  Future<CoreAuditVerification> verification({String? checkpoint}) async {
    if (checkpoint != null &&
        (checkpoint.isEmpty ||
            checkpoint.length > 512 ||
            checkpoint.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e))) {
      throw const LarenorServerException('invalid_request');
    }
    final raw = await _transport.request(
      'GET',
      '/admin/core-audit/${context.coreId}/${context.homeId}/verification',
      token: _token,
      queryParameters: checkpoint == null ? null : {'checkpoint': checkpoint},
    );
    if (raw == null || raw.length != 1 || !raw.containsKey('verification')) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreAuditVerification.fromJson(
      raw['verification'],
      expectedContext: context,
      expectedComparison: checkpoint != null,
    );
  }
}
