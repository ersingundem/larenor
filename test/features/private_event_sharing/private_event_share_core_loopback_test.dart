import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/private_event_sharing/data/private_event_share_account_api.dart';
import 'package:larenor/features/private_event_sharing/domain/private_event_share_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _account = '33333333333333333333333333333333';
const _sessionId = '44444444444444444444444444444444';
const _camera = '55555555555555555555555555555555';
const _event = '66666666666666666666666666666666';
const _recipient = '77777777777777777777777777777777';
const _share = '88888888888888888888888888888888';
const _expiredShare = '99999999999999999999999999999999';
const _artifact = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _pipeline = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _audit = 'cccccccccccccccccccccccccccccccc';
const _commandCreate = 'dddddddddddddddddddddddddddddddd';
const _commandRevoke = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _accessToken = 'private_event_access_token_123456789012345';
const _expiredToken = 'private_event_expired_token_1234567890123';
const _sessionToken = 'private_event_session_token_1234567890123';
const _sourceDigest =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _outputDigest =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _proof =
    '3333333333333333333333333333333333333333333333333333333333333333';
const _consent = 'ffffffffffffffffffffffffffffffff';

final class _ShareCore {
  _ShareCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  final bytes = utf8.encode('redacted-event-bytes-without-private-metadata');
  int revision = 1;
  bool created = false, consumed = false, revoked = false;
  bool policyConfigured = false;
  int consents = 0;
  int downloads = 0, oneTimeDenials = 0, revokeDenials = 0, expiryDenials = 0;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_ShareCore> start() async =>
      _ShareCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_sessionToken') {
      return _error(request, 401);
    }
    final root = '/api/v1/private-event-sharing/$_core/$_home/$_camera/$_event';
    final policyRoot =
        '/api/v1/admin/private-event-sharing/$_core/$_home/policy';
    final path = request.uri.path;
    if (request.method == 'GET' && path == '/api/v1/admin/users') {
      return _json(request, {
        'users': [
          _user(_account, 'admin', 'admin'),
          _user(_recipient, 'reviewer', 'member'),
        ],
      });
    }
    if (request.method == 'GET' && path == policyRoot) {
      return _json(request, _policy());
    }
    if (request.method == 'PUT' && path == policyRoot) {
      final body = await _body(request);
      if (body['expectedRevision'] != 0 ||
          body['grantorIds'].toString() != '[$_account]' ||
          body['recipientIds'].toString() != '[$_recipient]' ||
          body['redactionMode'] != 'full_frame_blur') {
        return _error(request, 400);
      }
      policyConfigured = true;
      return _json(request, _policy());
    }
    if (request.method == 'GET' && path == '$root/context') {
      return _json(request, _authority());
    }
    if (request.method == 'GET' && path == root) {
      return _json(request, {
        'authority': _authority(),
        'export': {
          'schemaVersion': 1,
          'coreId': _core,
          'homeId': _home,
          'cameraId': _camera,
          'eventId': _event,
          'shareRevision': revision,
          'shares': created ? [_snapshotShare()] : <Object>[],
        },
        'audit': {
          'schemaVersion': 1,
          'shareRevision': revision,
          'truncated': false,
          'events': <Object>[],
        },
      });
    }
    if (request.method == 'POST' && path == '$root/preview') {
      final body = await _body(request);
      if (body['expectedShareRevision'] != revision ||
          body['masks'].toString() != '[face, license_plate]' ||
          body['removedMetadata'].toString() !=
              '[device_serial, gps, camera_name, network_address]') {
        return _error(request, 400);
      }
      return _json(request, {
        'authority': _authority(),
        'transformation': {
          'sourceDigest': _sourceDigest,
          'outputDigest': _outputDigest,
          'outputArtifactId': _artifact,
          'pipelineId': _pipeline,
          'pipelineRevision': 5,
          'masks': ['face', 'license_plate'],
          'removedMetadata': [
            'device_serial',
            'gps',
            'camera_name',
            'network_address',
          ],
          'proof': _proof,
        },
      });
    }
    if (request.method == 'POST' && path == '$root/consents') {
      final body = await _body(request);
      if (!policyConfigured ||
          body['expectedPolicyRevision'] != 1 ||
          body['recipientId'] != _recipient ||
          body['purpose'] != 'incident review' ||
          body['masks'].toString() != '[face, license_plate]') {
        return _error(request, 409);
      }
      consents++;
      return _json(request, {
        'schemaVersion': 1,
        'consentId': _consent,
        'revision': 1,
        'recipientId': _recipient,
        'purpose': 'incident review',
        'accessMode': 'one_time',
        'expiresAt': body['expiresAt'],
        'requiredMasks': ['face', 'license_plate'],
        'requiredMetadata': [
          'device_serial',
          'gps',
          'camera_name',
          'network_address',
        ],
      }, 201);
    }
    if (request.method == 'POST' && path == '$root/shares') {
      final body = await _body(request);
      if (body['commandId'] != _commandCreate ||
          body['expectedShareRevision'] != 1 ||
          body['accessMode'] != 'one_time') {
        return _error(request, 409);
      }
      created = true;
      revision = 2;
      return _json(request, {
        'auditId': _audit,
        'commandId': _commandCreate,
        'action': 'created',
        'shareRevision': revision,
        'accessToken': _accessToken,
        'share': _wireShare(),
      });
    }
    if (request.method == 'POST' && path == '$root/revoke') {
      final body = await _body(request);
      if (body['commandId'] != _commandRevoke ||
          body['shareId'] != _share ||
          body['expectedShareRevision'] != 2) {
        return _error(request, 409);
      }
      revoked = true;
      revision = 3;
      return _json(request, {
        'auditId': _audit,
        'commandId': _commandRevoke,
        'action': 'revoked',
        'shareRevision': revision,
        'accessToken': '',
        'share': _wireShare(),
      });
    }
    if (request.method == 'POST' && path == '$root/download') {
      downloads++;
      final body = await _body(request);
      if (body['accessId'] == _expiredShare &&
          body['accessToken'] == _expiredToken) {
        expiryDenials++;
        return _error(request, 404);
      }
      if (body['accessId'] != _share || body['accessToken'] != _accessToken) {
        return _error(request, 404);
      }
      if (revoked) {
        revokeDenials++;
        return _error(request, 404);
      }
      if (consumed) {
        oneTimeDenials++;
        return _error(request, 404);
      }
      consumed = true;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.binary
        ..headers.set('x-larenor-content-sha256', sha256.convert(bytes))
        ..headers.set(
          'content-disposition',
          'attachment; filename="event-$_share.bin"',
        )
        ..add(bytes);
      await request.response.close();
      return;
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _authority() => {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'accountId': _account,
    'sessionId': _sessionId,
    'cameraId': _camera,
    'eventId': _event,
    'coreRevision': 1,
    'homeRevision': 2,
    'accountRevision': 3,
    'membersRevision': 4,
    'cameraRevision': 5,
    'eventRevision': 6,
    'sessionRevision': 7,
    'shareRevision': revision,
    'canShare': true,
  };

  Map<String, dynamic> _user(String id, String username, String role) => {
    'id': id,
    'username': username,
    'role': role,
    'disabled': false,
    'mustChangePassword': false,
    'revision': 1,
    'createdAt': '2026-09-30T10:00:00Z',
  };

  Map<String, dynamic> _policy() => policyConfigured
      ? {
          'schemaVersion': 1,
          'revision': 1,
          'configured': true,
          'active': true,
          'grantorIds': [_account],
          'recipientIds': [_recipient],
          'purposes': ['incident review'],
          'accessModes': ['one_time'],
          'maxTtlSeconds': 3600,
          'requiredMasks': ['face', 'license_plate'],
          'requiredMetadata': [
            'device_serial',
            'gps',
            'camera_name',
            'network_address',
          ],
          'redactionMode': 'full_frame_blur',
          'capability': {
            'schemaVersion': 1,
            'mode': 'full_frame_blur',
            'targetedRecognition': false,
            'coversEntireFrame': true,
          },
        }
      : {'schemaVersion': 1, 'revision': 0, 'configured': false};

  Map<String, dynamic> _wireShare() => {
    'id': _share,
    'recipientId': _recipient,
    'purpose': 'incident review',
    'accessMode': 'one_time',
    'expiresAt':
        DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch /
        1000,
    'outputDigest': _outputDigest,
    'revoked': revoked,
    'consumed': consumed,
  };

  Map<String, dynamic> _snapshotShare() => {
    ..._wireShare(),
    'outputArtifactId': _artifact,
    'pipelineId': _pipeline,
    'pipelineRevision': 5,
    'maskTypes': ['face'],
    'removedMetadata': ['gps'],
  };

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object value, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  unawaited(request.response.close());
}

void _error(HttpRequest request, int status) => _json(request, {
  'error': {'code': 'share_unavailable'},
}, status);

ServerSession _session(String baseUrl) => ServerSession(
  endpoint: ServerEndpoint(baseUrl),
  accessToken: _sessionToken,
  refreshToken: 'private_event_refresh_token_1234567890123',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
  }),
  user: const ServerUser(
    id: _account,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

PrivateEventSharePolicyDraft _policyDraft() => PrivateEventSharePolicyDraft(
  recipientId: _recipient,
  purpose: 'incident review',
  ttlSeconds: 3600,
  accessMode: EventShareAccessMode.oneTime,
);

Matcher _unavailable() => throwsA(
  isA<LarenorServerException>().having(
    (error) => error.code,
    'code',
    'share_unavailable',
  ),
);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client previews redaction and enforces byte, one-time, revoke, and expiry gates over loopback', () async {
    final core = await _ShareCore.start();
    addTearDown(core.close);
    final transport = LarenorServerApi(endpoint: ServerEndpoint(core.baseUrl));
    addTearDown(transport.close);
    final api = PrivateEventShareAccountApi(
      transport,
      _session(core.baseUrl),
      cameraId: _camera,
      eventId: _event,
      isCurrent: () => true,
    );
    final initial = await api.setup();
    expect(initial.policy.configured, isFalse);
    final configured = await api.configurePolicy(_policyDraft());
    expect(configured.policy.fullFrameOnly, isTrue);
    final consent = await api.acceptConsent(_policyDraft());
    expect(core.consents, 1);
    final draft = consent.draftFor(_policyDraft())!;

    final preview = await api.preview(draft);
    expect(preview.covers(draft), isTrue);
    expect(preview.sourceDigest, isNot(preview.outputDigest));
    final created = await api.create(
      expectedRevision: 1,
      commandId: _commandCreate,
      draft: draft,
      preview: preview,
    );

    final download = await api.download(
      accessToken: created.accessToken,
      accessId: created.record.id,
    );
    expect(download.bytes, core.bytes);
    expect(download.digest, sha256.convert(core.bytes).toString());
    expect(download.fileName, 'event-$_share.bin');

    await expectLater(
      api.download(accessToken: _accessToken, accessId: _share),
      _unavailable(),
    );
    expect(core.oneTimeDenials, 1);

    final refreshed = await api.snapshot();
    expect(refreshed.revision, 2);
    expect(refreshed.shares.single.consumed, isTrue);
    await api.revoke(
      expectedRevision: refreshed.revision,
      commandId: _commandRevoke,
      shareId: _share,
    );
    await expectLater(
      api.download(accessToken: _accessToken, accessId: _share),
      _unavailable(),
    );
    expect(core.revokeDenials, 1);

    await expectLater(
      api.download(accessToken: _expiredToken, accessId: _expiredShare),
      _unavailable(),
    );
    expect(core.expiryDenials, 1);
    expect(core.downloads, 4);
  });
}
