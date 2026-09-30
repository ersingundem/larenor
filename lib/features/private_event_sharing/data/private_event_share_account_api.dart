import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/admin/domain/server_admin_models.dart';
import '../../server/domain/server_models.dart';
import '../domain/private_event_share_models.dart';
import 'private_event_share_api.dart';

typedef PrivateEventDownloadAdapter = Future<EventShareDownload> Function({
  required String path,
  required String token,
  required String accessToken,
  required String accessId,
});

final class PrivateEventShareAccountApi
    implements PrivateEventShareApi, PrivateEventShareSetupApi {
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
  String get _policyRoot =>
      '/admin/private-event-sharing/${_context.coreId}/${_context.homeId}/policy';

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
  Future<PrivateEventShareSetup> setup() async {
    _check();
    final responses = await Future.wait([
      _api.request('GET', _policyRoot, token: _session.accessToken),
      _api.request('GET', '/admin/users', token: _session.accessToken),
    ]);
    _check();
    final usersJson = _map(responses[1]);
    _exact(usersJson, const {'users'});
    final rawUsers = _list(usersJson['users']);
    if (rawUsers.isEmpty || rawUsers.length > 256) {
      throw const FormatException('invalid_response');
    }
    final users = rawUsers
        .map((value) => AdminUser.fromJson(_map(value)))
        .where((value) => !value.disabled && !value.mustChangePassword)
        .map(
          (value) => PrivateEventShareMember(
            id: value.id,
            username: value.username,
            canGrant: value.role == ServerRole.admin,
          ),
        )
        .toList(growable: false);
    if (users.isEmpty ||
        users.map((value) => value.id).toSet().length != users.length ||
        !users.any((value) => value.id == _session.user.id)) {
      throw const FormatException('invalid_response');
    }
    return PrivateEventShareSetup(
      currentUserId: _session.user.id,
      members: users,
      policy: _policyFrom(_map(responses[0])),
    );
  }

  @override
  Future<PrivateEventShareSetup> configurePolicy(
    PrivateEventSharePolicyDraft draft,
  ) async {
    final current = await setup();
    _validatePolicyDraft(draft, current);
    final json = _map(
      await _api.request(
        'PUT',
        _policyRoot,
        token: _session.accessToken,
        body: {
          'schemaVersion': 1,
          'expectedRevision': current.policy.revision,
          'active': true,
          'grantorIds': [current.currentUserId],
          'recipientIds': [draft.recipientId],
          'purposes': [draft.purpose.trim()],
          'accessModes': [_accessModeWire(draft.accessMode)],
          'maxTtlSeconds': draft.ttlSeconds,
          'requiredMasks': const ['face', 'license_plate'],
          'requiredMetadata': const [
            'device_serial',
            'gps',
            'camera_name',
            'network_address',
          ],
          'redactionMode': 'full_frame_blur',
        },
      ),
    );
    _check();
    final policy = _policyFrom(json);
    if (!policy.configured || policy.revision != current.policy.revision + 1) {
      throw const FormatException('invalid_response');
    }
    _authority = null;
    return PrivateEventShareSetup(
      currentUserId: current.currentUserId,
      members: current.members,
      policy: policy,
    );
  }

  @override
  Future<PrivateEventShareConsent> acceptConsent(
    PrivateEventSharePolicyDraft draft,
  ) async {
    final current = await setup();
    _validatePolicyDraft(draft, current);
    final policy = current.policy;
    if (!policy.configured ||
        !policy.active ||
        !policy.grantorIds.contains(current.currentUserId) ||
        !policy.recipientIds.contains(draft.recipientId) ||
        !policy.purposes.contains(draft.purpose.trim()) ||
        !policy.accessModes.contains(draft.accessMode) ||
        draft.ttlSeconds > policy.maxTtlSeconds ||
        !policy.fullFrameOnly) {
      throw const LarenorServerException('consent_scope_changed');
    }
    final authority = await _loadAuthority();
    if (!authority.canShare) {
      throw const LarenorServerException('forbidden');
    }
    // The protocol carries an absolute expiry. Leave a narrow transport/clock
    // margin so an exact policy maximum is not exceeded while the request is in
    // flight; larger device clock drift still fails closed at Core.
    final consentSeconds = draft.ttlSeconds > 90 ? draft.ttlSeconds - 30 : 60;
    final expires = DateTime.now().toUtc().add(
      Duration(seconds: consentSeconds),
    );
    final json = _map(
      await _api.request(
        'POST',
        '$_root/consents',
        token: _session.accessToken,
        body: {
          ..._scope(authority),
          'expectedPolicyRevision': policy.revision,
          'recipientId': draft.recipientId,
          'purpose': draft.purpose.trim(),
          'expiresAt': expires.millisecondsSinceEpoch / 1000,
          'accessMode': _accessModeWire(draft.accessMode),
          'masks': policy.requiredMasks.map(_mask).toList(),
          'removedMetadata': policy.requiredMetadata.map(_metadata).toList(),
        },
      ),
    );
    _check();
    _exact(json, const {
      'schemaVersion',
      'consentId',
      'revision',
      'recipientId',
      'purpose',
      'accessMode',
      'expiresAt',
      'requiredMasks',
      'requiredMetadata',
    });
    if (json['schemaVersion'] != 1 ||
        json['recipientId'] != draft.recipientId ||
        json['purpose'] != draft.purpose.trim() ||
        _accessMode(json['accessMode']) != draft.accessMode) {
      throw const FormatException('invalid_response');
    }
    final consent = PrivateEventShareConsent(
      id: _id(json['consentId']),
      revision: _revision(json['revision']),
      recipientId: _id(json['recipientId']),
      purpose: _text(json['purpose'], 200),
      accessMode: _accessMode(json['accessMode']),
      expiresAt: _time(json['expiresAt']),
      masks: _list(json['requiredMasks']).map(_maskValue).toSet(),
      removedMetadata: _list(json['requiredMetadata'])
          .map(_metadataValue)
          .toSet(),
    );
    if (consent.expiresAt.isAfter(expires) ||
        !consent.expiresAt.isAfter(DateTime.now().toUtc()) ||
        consent.masks.length != policy.requiredMasks.length ||
        !consent.masks.containsAll(policy.requiredMasks) ||
        consent.removedMetadata.length != policy.requiredMetadata.length ||
        !consent.removedMetadata.containsAll(policy.requiredMetadata)) {
      throw const FormatException('invalid_response');
    }
    return consent;
  }

  void _validatePolicyDraft(
    PrivateEventSharePolicyDraft draft,
    PrivateEventShareSetup current,
  ) {
    if (!current.members.any((value) => value.id == draft.recipientId) ||
        !current.members.any(
          (value) => value.id == current.currentUserId && value.canGrant,
        ) ||
        draft.purpose.trim().isEmpty ||
        draft.purpose.trim().length > 200 ||
        draft.ttlSeconds < 60 ||
        draft.ttlSeconds > 604800) {
      throw const LarenorServerException('invalid_request');
    }
  }

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

String _accessModeWire(EventShareAccessMode value) =>
    value == EventShareAccessMode.oneTime ? 'one_time' : 'time_bound';

PrivateEventSharePolicy _policyFrom(Map<String, dynamic> value) {
  if (value['configured'] == false) {
    _exact(value, const {'schemaVersion', 'revision', 'configured'});
    if (value['schemaVersion'] != 1 || value['revision'] != 0) {
      throw const FormatException('invalid_response');
    }
    return PrivateEventSharePolicy(
      revision: 0,
      configured: false,
      active: false,
      grantorIds: const [],
      recipientIds: const [],
      purposes: const [],
      accessModes: const {},
      maxTtlSeconds: 0,
      requiredMasks: const {},
      requiredMetadata: const {},
      fullFrameOnly: false,
    );
  }
  _exact(value, const {
    'schemaVersion',
    'revision',
    'configured',
    'active',
    'grantorIds',
    'recipientIds',
    'purposes',
    'accessModes',
    'maxTtlSeconds',
    'requiredMasks',
    'requiredMetadata',
    'redactionMode',
    'capability',
  });
  final capability = _map(value['capability']);
  _exact(capability, const {
    'schemaVersion',
    'mode',
    'targetedRecognition',
    'coversEntireFrame',
  });
  final fullFrameOnly =
      capability['schemaVersion'] == 1 &&
      capability['mode'] == 'full_frame_blur' &&
      capability['targetedRecognition'] == false &&
      capability['coversEntireFrame'] == true &&
      value['redactionMode'] == 'full_frame_blur';
  if (value['schemaVersion'] != 1 ||
      value['configured'] != true ||
      value['active'] is! bool ||
      value['maxTtlSeconds'] is! int ||
      !fullFrameOnly) {
    throw const FormatException('invalid_response');
  }
  final grantors = _list(value['grantorIds']).map(_id).toList();
  final recipients = _list(value['recipientIds']).map(_id).toList();
  final purposes = _list(value['purposes'])
      .map((item) => _text(item, 200))
      .toList();
  final accessModes = _list(value['accessModes']).map(_accessMode).toSet();
  final masks = _list(value['requiredMasks']).map(_maskValue).toSet();
  final metadata = _list(value['requiredMetadata']).map(_metadataValue).toSet();
  final ttl = value['maxTtlSeconds'] as int;
  if (grantors.isEmpty ||
      grantors.length > 128 ||
      grantors.toSet().length != grantors.length ||
      recipients.isEmpty ||
      recipients.length > 128 ||
      recipients.toSet().length != recipients.length ||
      purposes.isEmpty ||
      purposes.length > 16 ||
      purposes.toSet().length != purposes.length ||
      accessModes.isEmpty ||
      masks.isEmpty ||
      metadata.isEmpty ||
      ttl < 60 ||
      ttl > 604800) {
    throw const FormatException('invalid_response');
  }
  return PrivateEventSharePolicy(
    revision: _revision(value['revision']),
    configured: true,
    active: _bool(value['active']),
    grantorIds: grantors,
    recipientIds: recipients,
    purposes: purposes,
    accessModes: accessModes,
    maxTtlSeconds: ttl,
    requiredMasks: masks,
    requiredMetadata: metadata,
    fullFrameOnly: fullFrameOnly,
  );
}

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
