import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_preparation_models.dart';

class MediaPreparationPage {
  const MediaPreparationPage(this.preparations, this.nextBefore);
  final List<ServerMediaPreparation> preparations;
  final int? nextBefore;
}

/// Durable Server metadata only. No worker or installation endpoint.
class ServerMediaPreparationsApi {
  const ServerMediaPreparationsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;
  static const root = '/admin/media/preparations';
  static const pageSize = 10;
  Never _invalid() => throw const LarenorServerException('invalid_response');
  ServerMediaPreparation _record(Object? value) =>
      ServerMediaPreparation.fromJson(
        mediaObject(value, {'preparation'})['preparation'],
      );
  Future<MediaPreparationPage> list({int? before}) async {
    if (before != null) mediaInteger(before);
    final map = mediaObject(
      await api.request(
        'GET',
        root,
        token: token,
        queryParameters: {
          'limit': '$pageSize',
          if (before != null) 'before': '$before',
        },
      ),
      {'preparations', 'nextBefore'},
    );
    final values = map['preparations'];
    if (values is! List || values.length > pageSize) _invalid();
    final records = values.map(ServerMediaPreparation.fromJson).toList();
    final next = map['nextBefore'] == null
        ? null
        : mediaInteger(map['nextBefore']);
    if (records.map((r) => r.id).toSet().length != records.length ||
        (next != null &&
            (records.isEmpty || (before != null && next >= before))))
      _invalid();
    return MediaPreparationPage(List.unmodifiable(records), next);
  }

  Future<ServerMediaPreparation> create(MediaPreparationRequest request) async {
    final record = _record(
      await api.request('POST', root, token: token, body: request.toJson()),
    );
    if (!request.accepts(record)) _invalid();
    return record;
  }

  Future<ServerMediaPreparation> get(
    String id, {
    ServerMediaPreparation? previous,
  }) async {
    mediaId(id);
    final record = _record(await api.request('GET', '$root/$id', token: token));
    if (record.id != id) _invalid();
    if (previous != null) _continuity(previous, record);
    return record;
  }

  void _continuity(
    ServerMediaPreparation before,
    ServerMediaPreparation after,
  ) {
    if (!before.sameIdentity(after) ||
        after.revision < before.revision ||
        after.updatedAt.isBefore(before.updatedAt))
      _invalid();
  }

  Future<ServerMediaPreparation> cancel(ServerMediaPreparation previous) async {
    final record = _record(
      await api.request(
        'POST',
        '$root/${previous.id}/cancel',
        token: token,
        body: {'expectedRevision': previous.revision},
      ),
    );
    _continuity(previous, record);
    if (record.prepared) _invalid();
    return record;
  }

  @override
  String toString() => 'ServerMediaPreparationsApi';
}
