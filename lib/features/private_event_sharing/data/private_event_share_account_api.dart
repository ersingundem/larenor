import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/private_event_share_models.dart';
import 'private_event_share_api.dart';

typedef PrivateEventDownloadAdapter = Future<EventShareDownload> Function({
  required String path,
  required String token,
  required String accessToken,
  required String accessId,
});

final class PrivateEventShareAccountApi implements PrivateEventShareApi {
  PrivateEventShareAccountApi(
    LarenorServerApi api,
    this._session, {
    required this.cameraId,
    required this.eventId,
    required this._isCurrent,
    PrivateEventDownloadAdapter? downloadAdapter,
  }) : _api = api,
       _downloadAdapter =
           downloadAdapter ??
           (({
             required String path,
             required String token,
             required String accessToken,
             required String accessId,
           }) => _download(
             endpoint: api.endpoint,
             path: path,
             token: token,
             accessToken: accessToken,
             accessId: accessId,
           ));

  final LarenorServerApi _api;
  final ServerSession _session;
  final String cameraId, eventId;
  final bool Function() _isCurrent;
  final PrivateEventDownloadAdapter _downloadAdapter;
  EventShareAuthority? _authority;
  bool _retired = false;

  ServerContext get _context => _session.context!;
  String get _root =>
      '/private-event-sharing/${_context.coreId}/${_context.homeId}/$cameraId/$eventId';

  void _check() {
    if (!_retired && _session.context != null && _isCurrent()) return;
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<EventShareAuthority> _loadAuthority() async {
    _check();
    final json = _map(
      await _api.request('GET', '$_root/context', token: _session.accessToken),
    );
    _check();
    final value = _authorityFrom(json);
    if (value.coreId != _context.coreId ||
        value.homeId != _context.homeId ||
        value.accountId != _session.user.id ||
        value.cameraId != cameraId ||
        value.eventId != eventId) {
      throw const FormatException('authority_changed');
    }
    _authority = value;
    return value;
  }

  Map<String, dynamic> _scope(EventShareAuthority value) => {
    'schemaVersion': 1,
    'coreRevision': value.coreRevision,
    'homeRevision': value.homeRevision,
    'accountRevision': value.accountRevision,
    'membersRevision': value.membersRevision,
    'cameraRevision': value.cameraRevision,
    'eventRevision': value.eventRevision,
    'sessionRevision': value.sessionRevision,
    'expectedShareRevision': value.shareRevision,
  };

  @override
  Future<EventShareSnapshot> snapshot() async {
    final authority = await _loadAuthority();
    final json = _map(
      await _api.request(
        'GET',
        _root,
        token: _session.accessToken,
        queryParameters: const {'limit': '256'},
      ),
    );
    _check();
    _exact(json, const {'authority', 'export', 'audit'});
    final responseAuthority = _authorityFrom(_map(json['authority']));
    if (!_sameAuthority(authority, responseAuthority)) {
      throw const FormatException('authority_changed');
    }
    final exported = _map(json['export']);
    final audited = _map(json['audit']);
    _exact(exported, const {
      'schemaVersion',
      'coreId',
      'homeId',
      'cameraId',
      'eventId',
      'shareRevision',
      'shares',
    });
    _exact(audited, const {
      'schemaVersion',
      'shareRevision',
      'truncated',
      'events',
    });
    if (exported['schemaVersion'] != 1 ||
        audited['schemaVersion'] != 1 ||
        exported['coreId'] != authority.coreId ||
        exported['homeId'] != authority.homeId ||
        exported['cameraId'] != authority.cameraId ||
        exported['eventId'] != authority.eventId ||
        audited['truncated'] is! bool ||
        exported['shareRevision'] != audited['shareRevision'] ||
        exported['shareRevision'] != authority.shareRevision) {
      throw const FormatException('authority_changed');
    }
    final shares = _list(exported['shares'])
        .map((raw) {
          final value = _map(raw);
          _exact(value, const {
            'id',
            'recipientId',
            'purpose',
            'accessMode',
            'expiresAt',
            'outputArtifactId',
            'outputDigest',
            'pipelineId',
            'pipelineRevision',
            'maskTypes',
            'removedMetadata',
            'revoked',
            'consumed',
          });
          return PrivateEventShareRecord(
            id: _id(value['id']),
            recipientId: _id(value['recipientId']),
            purpose: _text(value['purpose'], 200),
            accessMode: _accessMode(value['accessMode']),
            expiresAt: _time(value['expiresAt']),
            outputDigest: _digest(value['outputDigest']),
            revoked: _bool(value['revoked']),
            consumed: _bool(value['consumed']),
          );
        })
        .toList(growable: false);
    final audit = _list(audited['events'])
        .map((raw) {
          final value = _map(raw);
          _exact(value, const {
            'auditId',
            'action',
            'actorId',
            'recipientId',
            'shareId',
            'shareRevision',
            'occurredAt',
          });
          return EventShareAuditEntry(
            auditId: _id(value['auditId']),
            action: _text(value['action'], 16),
            actorId: _id(value['actorId']),
            recipientId: _id(value['recipientId']),
            shareId: _id(value['shareId']),
            revision: _revision(value['shareRevision']),
            occurredAt: _time(value['occurredAt']),
          );
        })
        .toList(growable: false);
    return EventShareSnapshot(
      revision: _revision(exported['shareRevision']),
      shares: shares,
      audit: audit,
      auditTruncated: audited['truncated'] as bool,
    );
  }

  @override
  Future<EventRedactionPreview> preview(EventShareDraft draft) async {
    final authority = _authority ?? await _loadAuthority();
    final json = _map(
      await _api.request(
        'POST',
        '$_root/preview',
        token: _session.accessToken,
        body: {
          ..._scope(authority),
          'masks': draft.masks.map(_mask).toList(),
          'removedMetadata': draft.removedMetadata.map(_metadata).toList(),
        },
      ),
    );
    _check();
    _exact(json, const {'authority', 'transformation'});
    final responseAuthority = _authorityFrom(_map(json['authority']));
    if (!_sameAuthority(authority, responseAuthority)) {
      throw const FormatException('authority_changed');
    }
    final value = _map(json['transformation']);
    _exact(value, const {
      'sourceDigest',
      'outputDigest',
      'outputArtifactId',
      'pipelineId',
      'pipelineRevision',
      'masks',
      'removedMetadata',
      'proof',
    });
    return EventRedactionPreview(
      previewId: _id(value['outputArtifactId']),
      sourceDigest: _digest(value['sourceDigest']),
      outputDigest: _digest(value['outputDigest']),
      outputArtifactId: _id(value['outputArtifactId']),
      pipelineId: _id(value['pipelineId']),
      pipelineRevision: _revision(value['pipelineRevision']),
      proof: _digest(value['proof']),
      masks: _list(value['masks']).map((v) => _maskValue(v)).toSet(),
      removedMetadata: _list(value['removedMetadata'])
          .map((v) => _metadataValue(v))
          .toSet(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<CreatedPrivateEventShare> create({
    required int expectedRevision,
    required String commandId,
    required EventShareDraft draft,
    required EventRedactionPreview preview,
  }) async {
    final authority = _authority ?? await _loadAuthority();
    if (authority.shareRevision != expectedRevision) {
      throw const FormatException('authority_changed');
    }
    final expires = DateTime.now().toUtc().add(
      Duration(seconds: draft.ttlSeconds),
    );
    final json = _map(
      await _api.request(
        'POST',
        '$_root/shares',
        token: _session.accessToken,
        body: {
          ..._scope(authority),
          'commandId': commandId,
          'consentId': draft.consentId,
          'consentRevision': draft.consentRevision,
          'recipientId': draft.recipientId,
          'purpose': draft.purpose,
          'expiresAt': expires.millisecondsSinceEpoch / 1000,
          'accessMode': draft.accessMode == EventShareAccessMode.oneTime
              ? 'one_time'
              : 'time_bound',
          'transformation': {
            'sourceDigest': preview.sourceDigest,
            'outputDigest': preview.outputDigest,
            'outputArtifactId': preview.outputArtifactId,
            'pipelineId': preview.pipelineId,
            'pipelineRevision': preview.pipelineRevision,
            'masks': preview.masks.map(_mask).toList(),
            'removedMetadata': preview.removedMetadata.map(_metadata).toList(),
            'proof': preview.proof,
          },
        },
      ),
    );
    _check();
    _exact(json, const {
      'auditId',
      'commandId',
      'action',
      'shareRevision',
      'accessToken',
      'share',
    });
    if (json['commandId'] != commandId ||
        json['action'] != 'created' ||
        _revision(json['shareRevision']) <= expectedRevision) {
      throw const FormatException('invalid_response');
    }
    return CreatedPrivateEventShare(
      record: _shareFrom(_map(json['share'])),
      accessToken: _token(json['accessToken']),
    );
  }

  @override
  Future<void> revoke({
    required int expectedRevision,
    required String commandId,
    required String shareId,
  }) async {
    final authority = _authority ?? await _loadAuthority();
    if (authority.shareRevision != expectedRevision) {
      throw const FormatException('authority_changed');
    }
    final json = _map(
      await _api.request(
        'POST',
        '$_root/revoke',
        token: _session.accessToken,
        body: {
          ..._scope(authority),
          'expectedShareRevision': expectedRevision,
          'commandId': commandId,
          'shareId': shareId,
        },
      ),
    );
    _check();
    _exact(json, const {
      'auditId',
      'commandId',
      'action',
      'shareRevision',
      'accessToken',
      'share',
    });
    final share = _shareFrom(_map(json['share']));
    if (json['commandId'] != commandId ||
        json['action'] != 'revoked' ||
        json['accessToken'] != '' ||
        share.id != shareId ||
        !share.revoked ||
        _revision(json['shareRevision']) <= expectedRevision) {
      throw const FormatException('invalid_response');
    }
  }

  @override
  Future<EventShareDownload> download({
    required String accessToken,
    required String accessId,
  }) {
    _check();
    return _downloadAdapter(
      path: '$_root/download',
      token: _session.accessToken,
      accessToken: accessToken,
      accessId: accessId,
    );
  }

  void retire() => _retired = true;

  PrivateEventShareRecord _shareFrom(Map<String, dynamic> value) {
    _exact(value, const {
      'id',
      'recipientId',
      'purpose',
      'accessMode',
      'expiresAt',
      'outputDigest',
      'revoked',
      'consumed',
    });
    return PrivateEventShareRecord(
      id: _id(value['id']),
      recipientId: _id(value['recipientId']),
      purpose: _text(value['purpose'], 200),
      accessMode: _accessMode(value['accessMode']),
      expiresAt: _time(value['expiresAt']),
      outputDigest: _digest(value['outputDigest']),
      revoked: _bool(value['revoked']),
      consumed: _bool(value['consumed']),
    );
  }

  static Future<EventShareDownload> _download({
    required ServerEndpoint endpoint,
    required String path,
    required String token,
    required String accessToken,
    required String accessId,
  }) async {
    if (!RegExp(
          r'^/private-event-sharing/[0-9a-f]{32}/[0-9a-f]{32}/[0-9a-f]{32}/[0-9a-f]{32}/download$',
        ).hasMatch(path) ||
        !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(token) ||
        !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(accessToken) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(accessId)) {
      throw const LarenorServerException('invalid_request');
    }
    const maximum = 64 * 1024 * 1024;
    final client = ServerBoundClient(baseUrl: endpoint.baseUrl);
    final body = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'accessId': accessId,
          'accessToken': accessToken,
        }),
      ),
    );
    final request = http.Request('POST', endpoint.api(path))
      ..headers['accept'] = 'application/octet-stream'
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json'
      ..bodyBytes = body;
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _drain(response.stream, 8192);
        throw LarenorServerException(switch (response.statusCode) {
          401 => 'invalid_session',
          403 => 'forbidden',
          404 => 'share_unavailable',
          409 => 'conflict',
          _ => 'server_unavailable',
        });
      }
      if ((response.contentLength ?? 0) > maximum ||
          response.headers['content-type']?.split(';').first.trim() !=
              'application/octet-stream') {
        throw const LarenorServerException('invalid_response');
      }
      final digest = response.headers['x-larenor-content-sha256'];
      final disposition = response.headers['content-disposition'];
      final match = disposition == null
          ? null
          : RegExp(r'^attachment; filename="event-([0-9a-f]{32})\.bin"$')
                .firstMatch(disposition);
      if (digest == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
          match == null) {
        throw const LarenorServerException('invalid_response');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maximum) {
          throw const LarenorServerException('invalid_response');
        }
        if (chunk.isNotEmpty) bytes.add(chunk);
      }
      final value = bytes.takeBytes();
      if (value.isEmpty || sha256.convert(value).toString() != digest) {
        value.fillRange(0, value.length, 0);
        throw const LarenorServerException('invalid_response');
      }
      return EventShareDownload(
        shareId: match.group(1)!,
        fileName: 'event-${match.group(1)!}.bin',
        digest: digest,
        bytes: value,
      );
    } on TimeoutException {
      throw const LarenorServerException('timeout');
    } on LarenorServerException {
      rethrow;
    } on http.ClientException {
      throw const LarenorServerException('server_unavailable');
    } finally {
      body.fillRange(0, body.length, 0);
      request.bodyBytes.fillRange(0, request.bodyBytes.length, 0);
      client.close();
    }
  }
}

Future<void> _drain(Stream<List<int>> stream, int maximum) async {
  var length = 0;
  await for (final chunk in stream) {
    length += chunk.length;
    if (length > maximum) {
      throw const LarenorServerException('invalid_response');
    }
  }
}

EventShareAuthority _authorityFrom(Map<String, dynamic> j) {
  _exact(j, const {
    'schemaVersion',
    'coreId',
    'homeId',
    'accountId',
    'sessionId',
    'cameraId',
    'eventId',
    'coreRevision',
    'homeRevision',
    'accountRevision',
    'membersRevision',
    'cameraRevision',
    'eventRevision',
    'sessionRevision',
    'shareRevision',
    'canShare',
  });
  if (j['schemaVersion'] != 1) {
    throw const FormatException('invalid_response');
  }
  return EventShareAuthority(
    coreId: _id(j['coreId']),
    homeId: _id(j['homeId']),
    accountId: _id(j['accountId']),
    sessionId: _id(j['sessionId']),
    cameraId: _id(j['cameraId']),
    eventId: _id(j['eventId']),
    coreRevision: _revision(j['coreRevision']),
    homeRevision: _revision(j['homeRevision']),
    accountRevision: _revision(j['accountRevision']),
    membersRevision: _revision(j['membersRevision']),
    cameraRevision: _revision(j['cameraRevision']),
    eventRevision: _revision(j['eventRevision']),
    sessionRevision: _revision(j['sessionRevision']),
    shareRevision: _revision(j['shareRevision']),
    canShare: _bool(j['canShare']),
  );
}

bool _sameAuthority(EventShareAuthority a, EventShareAuthority b) =>
    a.coreId == b.coreId &&
    a.homeId == b.homeId &&
    a.accountId == b.accountId &&
    a.sessionId == b.sessionId &&
    a.cameraId == b.cameraId &&
    a.eventId == b.eventId &&
    a.shareRevision == b.shareRevision;
Map<String, dynamic> _map(Object? v) {
  if (v is! Map<String, dynamic>) {
    throw const FormatException('invalid_response');
  }
  return v;
}

void _exact(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw const FormatException('invalid_response');
  }
}

List _list(Object? v) {
  if (v is! List) throw const FormatException('invalid_response');
  return v;
}

String _id(Object? v) {
  if (v is! String || v.isEmpty || v.length > 128) {
    throw const FormatException('invalid_response');
  }
  return v;
}

String _text(Object? v, int max) {
  if (v is! String || v.isEmpty || v.length > max) {
    throw const FormatException('invalid_response');
  }
  return v;
}

String _digest(Object? v) {
  if (v is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
    throw const FormatException('invalid_response');
  }
  return v;
}

String _token(Object? v) {
  if (v is! String || !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(v)) {
    throw const FormatException('invalid_response');
  }
  return v;
}

int _revision(Object? v) {
  if (v is! int || v < 1) throw const FormatException('invalid_response');
  return v;
}

bool _bool(Object? v) {
  if (v is! bool) throw const FormatException('invalid_response');
  return v;
}

EventShareAccessMode _accessMode(Object? value) => switch (value) {
  'one_time' => EventShareAccessMode.oneTime,
  'time_bound' => EventShareAccessMode.timeBound,
  _ => throw const FormatException('invalid_response'),
};

DateTime _time(Object? v) {
  if (v is! num || !v.isFinite || v <= 0) {
    throw const FormatException('invalid_response');
  }
  return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(), isUtc: true);
}

String _mask(EventShareMask v) =>
    v == EventShareMask.face ? 'face' : 'license_plate';
EventShareMask _maskValue(Object? v) => v == 'face'
    ? EventShareMask.face
    : v == 'license_plate'
    ? EventShareMask.licensePlate
    : throw const FormatException('invalid_response');
String _metadata(EventShareMetadata v) => switch (v) {
  EventShareMetadata.deviceSerial => 'device_serial',
  EventShareMetadata.gps => 'gps',
  EventShareMetadata.cameraName => 'camera_name',
  EventShareMetadata.networkAddress => 'network_address',
};
EventShareMetadata _metadataValue(Object? v) => switch (v) {
  'device_serial' => EventShareMetadata.deviceSerial,
  'gps' => EventShareMetadata.gps,
  'camera_name' => EventShareMetadata.cameraName,
  'network_address' => EventShareMetadata.networkAddress,
  _ => throw const FormatException('invalid_response'),
};
