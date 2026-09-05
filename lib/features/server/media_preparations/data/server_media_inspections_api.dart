import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_preparation_models.dart';
import '../domain/server_media_inspection_models.dart';

class MediaInspectionPage {
  const MediaInspectionPage(this.inspections, this.nextBefore);
  final List<ServerMediaInspection> inspections;
  final int? nextBefore;
}

class ServerMediaInspectionsApi {
  const ServerMediaInspectionsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;
  static const root = '/admin/media/inspections';
  static const pageSize = 10;
  Never _invalid() => throw const LarenorServerException('invalid_response');
  Future<ServerMediaInspectionCapabilities> capabilities() async =>
      ServerMediaInspectionCapabilities.fromJson(
        await api.request('GET', '$root/capabilities', token: token),
      );
  Future<MediaInspectionPage> list({int? before}) async {
    if (before != null) mediaInteger(before);
    final json = mediaObject(
      await api.request(
        'GET',
        root,
        token: token,
        queryParameters: {
          'limit': '$pageSize',
          if (before != null) 'before': '$before',
        },
      ),
      {'inspections', 'nextBefore'},
    );
    final values = json['inspections'];
    if (values is! List || values.length > pageSize) _invalid();
    final records = values.map(ServerMediaInspection.fromJson).toList();
    final next = json['nextBefore'] == null
        ? null
        : mediaInteger(json['nextBefore']);
    if (records.map((r) => r.id).toSet().length != records.length ||
        records.any((r) => r.context != records.first.context) ||
        (next != null &&
            (records.isEmpty || (before != null && next >= before)))) {
      _invalid();
    }
    return MediaInspectionPage(List.unmodifiable(records), next);
  }

  ServerMediaInspection _record(
    Object? value, {
    ServerMediaInspection? previous,
    String? id,
  }) {
    final record = ServerMediaInspection.fromJson(
      mediaObject(value, {'inspection'})['inspection'],
    );
    if ((id != null && record.id != id) ||
        (previous != null &&
            (!record.sameIdentity(previous) ||
                record.revision < previous.revision ||
                record.updatedAt.isBefore(previous.updatedAt) ||
                (!previous.active &&
                    (record.state != previous.state ||
                        record.revision != previous.revision))))) {
      _invalid();
    }
    return record;
  }

  Future<ServerMediaInspection> create(
    ServerMediaInspectionRequest request,
  ) async {
    final record = _record(
      await api.request('POST', root, token: token, body: request.toJson()),
    );
    if (!request.accepts(record)) _invalid();
    return record;
  }

  Future<ServerMediaInspection> get(
    String id, {
    ServerMediaInspection? previous,
  }) async {
    mediaId(id);
    return _record(
      await api.request('GET', '$root/$id', token: token),
      id: id,
      previous: previous,
    );
  }

  Future<ServerMediaInspection> cancel(ServerMediaInspection previous) async {
    final record = _record(
      await api.request(
        'POST',
        '$root/${previous.id}/cancel',
        token: token,
        body: {'expectedRevision': previous.revision},
      ),
      previous: previous,
    );
    if (record.active && !record.cancelRequested) _invalid();
    return record;
  }

  @override
  String toString() => 'ServerMediaInspectionsApi';
}
