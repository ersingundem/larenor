import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_preparation_models.dart';
import '../domain/server_seerr_convergence.dart';

class ServerSeerrConvergenceApi {
  const ServerSeerrConvergenceApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;
  static const _root = '/admin/media/seerr-bootstraps';
  static const _pageSize = 10;
  static const _maximum = 64;

  Future<ServerSeerrConvergence?> findForInstallation(
    String installationId,
  ) async {
    mediaId(installationId);
    int? before;
    var count = 0;
    while (count < _maximum) {
      final map = mediaObject(
        await api.request(
          'GET',
          _root,
          token: token,
          queryParameters: {
            'limit': '$_pageSize',
            if (before != null) 'before': '$before',
          },
        ),
        {'bootstraps', 'nextBefore'},
      );
      final values = map['bootstraps'];
      if (values is! List || values.length > _pageSize) {
        throw const LarenorServerException('invalid_response');
      }
      final records = values.map(ServerSeerrConvergence.fromJson).toList();
      final matches = records.where(
        (item) => item.installationId == installationId,
      );
      if (matches.length > 1) {
        throw const LarenorServerException('invalid_response');
      }
      if (matches.isNotEmpty) return matches.single;
      count += records.length;
      final next = map['nextBefore'];
      if (next == null) return null;
      before = mediaInteger(next);
      if (records.isEmpty || count >= _maximum) {
        throw const LarenorServerException('invalid_response');
      }
    }
    throw const LarenorServerException('invalid_response');
  }
}
