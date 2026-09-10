import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/core_ha/data/core_ha_activity_controller.dart';
import 'package:larenor/features/core_ha/data/core_ha_api.dart';
import 'package:larenor/features/core_ha/data/core_ha_checkpoint_store.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../integration_test/support/synthetic_ha_server.dart';

enum _ProofMode { sound, foreignChain, rollbackClaim, malformed }

final class _HistoryCoreFixture {
  _HistoryCoreFixture._(this.server, this.contract, this.history);

  final HttpServer server;
  final Map<String, dynamic> contract, history;
  final methods = <String>[];
  final authorization = <String?>[];
  int historyReads = 0, verificationReads = 0, rejected = 0, restarts = 0;
  int sequence = 2;
  String chainId = 'c' * 32, headHash = 'd' * 64;
  String checkpoint = 'checkpoint-2';
  final acceptedCheckpoints = <String>{'checkpoint-2'};
  String role = 'admin';
  bool unauthorized = false;
  _ProofMode proofMode = _ProofMode.sound;
  Completer<void>? verificationGate;

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  int get port => server.port;
  String get coreId => contract['context']['coreId'] as String;
  String get homeId => contract['context']['homeId'] as String;
  String get resourceId => contract['resource']['ref']['id'] as String;
  String get historyPath =>
      '/api/v1/home-assistant/$coreId/$homeId/resources/$resourceId/history';
  String get verificationPath =>
      '/api/v1/admin/home-assistant/$coreId/$homeId/history/verification';

  static Future<_HistoryCoreFixture> start() async {
    final fixture = _HistoryCoreFixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      jsonDecode(File('contracts/home-assistant.v1.json').readAsStringSync())
          as Map<String, dynamic>,
      jsonDecode(
        File('contracts/home-assistant-history.v1.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  void advance() {
    sequence++;
    headHash = sequence.isEven ? 'd' * 64 : 'e' * 64;
    checkpoint = 'checkpoint-$sequence';
    acceptedCheckpoints.add(checkpoint);
  }

  void restartFromOlderBackup() {
    restarts++;
    sequence = 2;
    headHash = 'd' * 64;
    checkpoint = 'checkpoint-2';
    acceptedCheckpoints
      ..clear()
      ..add(checkpoint);
    proofMode = _ProofMode.sound;
  }

  Future<List<int>> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > 4096) {
        throw const FormatException('oversized');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<void> _reply(HttpRequest request, int status, Object body) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    try {
      await request.response.close();
    } on HttpException {
      // A retired Client is expected to close a delayed socket.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    methods.add(request.method);
    authorization.add(request.headers.value('authorization'));
    final path = request.uri.path;
    if (path == '/api/v1/auth/login' && request.method == 'POST') {
      final body = jsonDecode(utf8.decode(await _body(request))) as Map;
      if (body['username'] != 'fixture' || body['password'] != 'fixture-pass') {
        rejected++;
        await _reply(request, 401, {
          'error': {'code': 'unauthorized'},
        });
        return;
      }
      await _reply(request, 200, {
        'accessToken': 'fixture-access-token',
        'refreshToken': 'fixture-refresh-token',
        'expiresIn': 3600,
        'user': {
          'id': '9' * 32,
          'username': 'Fixture',
          'role': role,
          'mustChangePassword': false,
        },
      });
      return;
    }
    if (path == '/api/v1/context' && request.method == 'GET') {
      await _reply(request, 200, contract['context']);
      return;
    }
    if (unauthorized ||
        request.headers.value('authorization') !=
            'Bearer fixture-access-token') {
      rejected++;
      await _reply(request, 401, {
        'error': {'code': 'unauthorized'},
      });
      return;
    }
    if (path == historyPath && request.method == 'GET') {
      historyReads++;
      if (request.uri.queryParameters.keys.any(
        (key) => !{'limit', 'before'}.contains(key),
      )) {
        rejected++;
        await _reply(request, 400, {
          'error': {'code': 'invalid_request'},
        });
        return;
      }
      await _reply(request, 200, history['complete']['response']);
      return;
    }
    if (path == verificationPath && request.method == 'GET') {
      verificationReads++;
      final compared = request.uri.queryParameters['checkpoint'];
      if (request.uri.queryParameters.keys.any((key) => key != 'checkpoint')) {
        rejected++;
        await _reply(request, 400, {
          'error': {'code': 'invalid_request'},
        });
        return;
      }
      final gate = verificationGate;
      if (gate != null) await gate.future;
      if (compared != null &&
          proofMode == _ProofMode.sound &&
          !acceptedCheckpoints.contains(compared)) {
        await _reply(request, 409, {
          'error': {'code': 'conflict'},
        });
        return;
      }
      final resultChain = proofMode == _ProofMode.foreignChain
          ? 'f' * 32
          : chainId;
      final resultSequence = proofMode == _ProofMode.rollbackClaim
          ? sequence - 1
          : sequence;
      final resultHead = proofMode == _ProofMode.malformed
          ? 'broken'
          : headHash;
      await _reply(request, 200, {
        'verification': {
          'schemaVersion': 1,
          'scope': contract['context'],
          'chainId': resultChain,
          'sequence': resultSequence,
          'headHash': resultHead,
          'checkpoint': checkpoint,
          'verified': true,
          'comparedCheckpoint': compared != null,
          'causalityVerified': false,
        },
      });
      return;
    }
    rejected++;
    await _reply(request, 405, {
      'error': {'code': 'forbidden'},
    });
  }

  Future<void> close() => server.close(force: true);
}

final class _Sessions implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _Source implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;
  @override
  Future<void> write(HomeSource source) async {}
}

final class _CheckpointMemory implements CoreHaCheckpointBackend {
  final values = <String, String>{};
  int writes = 0;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }
}

final class _Journey {
  _Journey(this.fixture);
  final _HistoryCoreFixture fixture;
  late final network = FixtureNetwork(fixture.port);
  late final sessions = _Sessions();
  late final account = ServerAccountController(
    store: sessions,
    apiFactory: api,
  );
  late final home = HomeSessionController(store: _Source(), account: account);
  final owner = ValueNotifier(0);
  final checkpointBackend = _CheckpointMemory();
  bool current = true;
  CoreHaActivityController? controller;

  LarenorServerApi api(ServerEndpoint endpoint) => LarenorServerApi(
    endpoint: endpoint,
    client: IOClient(network.createHttpClient(null)),
  );

  HomeResourceRecord get target => HomeResourceRecord.fromJson(
    fixture.contract['resource'],
    expectedContext: ServerContext.fromJson(fixture.contract['context']),
  );

  Future<void> start() async {
    await account.signIn(
      baseUrl: fixture.baseUrl,
      username: 'fixture',
      password: 'fixture-pass',
      deviceName: 'History checkpoint fixture',
    );
    expect(account.session, isNotNull);
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
    controller = CoreHaActivityController(
      home,
      target,
      api,
      DateTime.now,
      () => current,
      owner,
      verifyIntegrity: true,
      checkpointStore: CoreHaCheckpointStore(backend: checkpointBackend),
      checkpointProtected: true,
    )..setVisible(true);
    await settle();
  }

  Future<void> settle() async {
    for (var attempt = 0; attempt < 300; attempt++) {
      final value = controller!;
      if (!value.busy &&
          (value.loaded || value.failure != null || !value.fresh)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for Client history controller');
  }

  Future<void> refresh() async {
    await controller!.refresh();
    await settle();
  }

  Future<void> close() async {
    controller?.dispose();
    home.dispose();
    account.dispose();
    owner.dispose();
    await fixture.close();
  }
}

void main() {
  test(
    'real Client HTTP pins, advances, rotates, and alarms after Core restore',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        final c = journey.controller!;
        expect(c.verification?.sequence, 2);
        expect(c.trustedCheckpoint, isNull);
        await c.pinCurrentCheckpoint();
        expect(c.trustedCheckpoint?.checkpoint, 'checkpoint-2');
        expect(journey.checkpointBackend.writes, 1);

        journey.fixture.advance();
        await journey.refresh();
        expect(c.trustedCompared, isTrue);
        expect(c.verification?.sequence, 3);
        expect(c.canRotateCheckpoint, isTrue);
        expect(journey.checkpointBackend.writes, 1);
        await c.rotateTrustedCheckpoint();
        expect(c.trustedCheckpoint?.checkpoint, 'checkpoint-3');
        expect(journey.checkpointBackend.writes, 2);

        journey.fixture.restartFromOlderBackup();
        await journey.refresh();
        expect(journey.fixture.restarts, 1);
        expect(c.checkpointAlarm, 'mismatch');
        expect(c.trustedCheckpoint?.checkpoint, 'checkpoint-3');
        expect(journey.checkpointBackend.writes, 2);
        expect(
          journey.fixture.methods.where((method) => method == 'GET').length,
          greaterThanOrEqualTo(5),
        );
        expect(
          journey.fixture.authorization
              .skip(2)
              .whereType<String>()
              .every((value) => value == 'Bearer fixture-access-token'),
          isTrue,
        );
        expect(journey.network.blocked, 0);
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'chain, rollback claim, and malformed proof raise retained alarms',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        final c = journey.controller!;
        await c.pinCurrentCheckpoint();
        final trusted = c.trustedCheckpoint;

        journey.fixture.proofMode = _ProofMode.foreignChain;
        await journey.refresh();
        expect(c.checkpointAlarm, 'mismatch');
        expect(c.trustedCheckpoint, trusted);

        journey.fixture.proofMode = _ProofMode.rollbackClaim;
        await journey.refresh();
        expect(c.checkpointAlarm, 'rollback');
        expect(c.trustedCheckpoint, trusted);

        journey.fixture.proofMode = _ProofMode.malformed;
        await journey.refresh();
        expect(c.checkpointAlarm, 'mismatch');
        expect(c.integrityFailure, 'invalid_response');
        expect(c.trustedCheckpoint, trusted);
        expect(journey.checkpointBackend.writes, 1);
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'late proof, auth loss, role loss, and local limits fail closed',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        final c = journey.controller!;
        await c.pinCurrentCheckpoint();
        journey.fixture.verificationGate = Completer<void>();
        final verificationBefore = journey.fixture.verificationReads;
        final pending = c.refresh();
        while (journey.fixture.verificationReads <= verificationBefore) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        journey.current = false;
        journey.owner.value++;
        c.setVisible(false);
        expect(c.entries, isEmpty);
        journey.fixture.verificationGate!.complete();
        await pending;
        expect(c.verification, isNull);
        expect(c.checkpointAlarm, isNull);
        expect(c.entries, isEmpty);

        final before = journey.fixture.verificationReads;
        final transport = journey.api(journey.account.session!.endpoint);
        final direct = CoreHaApi(
          transport,
          journey.account.session!.accessToken,
          journey.target,
          isCurrent: () => true,
        );
        await expectLater(
          direct.verifyHistory(checkpoint: 'x' * 513),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        await expectLater(
          direct.history(limit: 51),
          throwsA(isA<LarenorServerException>()),
        );
        expect(journey.fixture.verificationReads, before);
        transport.close();
      } finally {
        await journey.close();
      }

      final member = _Journey(await _HistoryCoreFixture.start())
        ..fixture.role = 'member';
      try {
        await member.start();
        expect(member.controller!.fresh, isFalse);
        expect(member.fixture.historyReads, 0);
        expect(member.fixture.verificationReads, 0);
      } finally {
        await member.close();
      }

      final unauthorized = _Journey(await _HistoryCoreFixture.start());
      try {
        await unauthorized.start();
        unauthorized.fixture.unauthorized = true;
        await unauthorized.refresh();
        expect(unauthorized.account.session, isNull);
        expect(unauthorized.controller!.fresh, isFalse);
        expect(unauthorized.controller!.loaded, isFalse);
        expect(unauthorized.controller!.entries, isEmpty);
        expect(unauthorized.controller!.checkpointAlarm, isNull);
      } finally {
        await unauthorized.close();
      }
    },
  );
}
