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
import 'package:larenor/features/core_ha/data/core_ha_event_checkpoint_store.dart';
import 'package:larenor/features/core_ha/domain/core_ha_activity_models.dart';
import 'package:larenor/features/core_ha/domain/core_ha_models.dart';
import 'package:larenor/features/core_ha/domain/core_ha_models.dart';
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
  int historyReads = 0,
      eventReads = 0,
      verificationReads = 0,
      rejected = 0,
      restarts = 0;
  int historyStatus = 200;
  int sequence = 2;
  String chainId = 'c' * 32, headHash = 'd' * 64;
  String eventChainId = 'e' * 32;
  int eventHead = 2, eventStatus = 200;
  String checkpoint = 'checkpoint-2';
  final acceptedCheckpoints = <String>{'checkpoint-2'};
  String role = 'admin';
  bool unauthorized = false;
  _ProofMode proofMode = _ProofMode.sound;
  Completer<void>? verificationGate;
  Completer<void>? eventGate;
  final eventAfter = <int?>[];
  Completer<void>? historyGate;

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  int get port => server.port;
  String get coreId => contract['context']['coreId'] as String;
  String get homeId => contract['context']['homeId'] as String;
  String get resourceId => contract['resource']['ref']['id'] as String;
  String get historyPath =>
      '/api/v1/home-assistant/$coreId/$homeId/resources/$resourceId/history';
  String get verificationPath =>
      '/api/v1/admin/home-assistant/$coreId/$homeId/history/verification';
  String get eventPath => '$historyPath/events';

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

  void serveRuleAttribution() {
    final entries = history['complete']['response']['entries'] as List;
    final first = entries.first as Map<String, dynamic>;
    final attribution = first['attribution'] as Map<String, dynamic>;
    attribution
      ..clear()
      ..addAll({
        'schemaVersion': 1,
        'correlationId':
            (first['receipt'] as Map<String, dynamic>)['requestId'],
        'source': 'core_rule',
        'reason': 'explicit_rule_execution',
        'serviceId': '2' * 32,
        'serviceRevision': 1,
        'ruleId': '3' * 32,
        'ruleRevision': 4,
        'executionId': (first['receipt'] as Map<String, dynamic>)['requestId'],
      });
  }

  void appendUnknownAttribution() {
    final entries = history['complete']['response']['entries'] as List;
    final unknown =
        jsonDecode(jsonEncode(entries.last)) as Map<String, dynamic>;
    final receipt = unknown['receipt'] as Map<String, dynamic>;
    receipt
      ..['requestId'] = '7' * 32
      ..['createdAt'] = '2026-09-05T11:59:59.000Z'
      ..['completedAt'] = '2026-09-05T11:59:59.000Z';
    (unknown['attribution'] as Map<String, dynamic>)
      ..clear()
      ..addAll({
        'schemaVersion': 1,
        'correlationId': '7' * 32,
        'source': 'unknown',
        'reason': 'unknown',
        'serviceId': null,
        'serviceRevision': null,
      });
    entries.add(unknown);
  }

  void advance() {
    sequence++;
    eventHead++;
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
      final gate = historyGate;
      if (gate != null) await gate.future;
      if (historyStatus != 200) {
        await _reply(request, historyStatus, {
          'error': {'code': 'server_unavailable'},
        });
        return;
      }
      await _reply(request, 200, history['complete']['response']);
      return;
    }
    if (path == eventPath && request.method == 'GET') {
      eventReads++;
      final pairs = request.uri.queryParametersAll;
      if (pairs.keys.any((key) => !{'limit', 'after'}.contains(key)) ||
          pairs.values.any((values) => values.length != 1)) {
        rejected++;
        await _reply(request, 400, {
          'error': {'code': 'invalid_request'},
        });
        return;
      }
      final gate = eventGate;
      if (gate != null) await gate.future;
      if (eventStatus != 200) {
        await _reply(request, eventStatus, {
          'error': {'code': 'server_unavailable'},
        });
        return;
      }
      final after =
          int.tryParse(request.uri.queryParameters['after'] ?? '') ?? 0;
      eventAfter.add(after == 0 ? null : after);
      final limit =
          int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
      final source = history['complete']['response']['entries'] as List;
      final end = (after + limit).clamp(0, eventHead);
      final events = <Object>[];
      for (
        var eventSequence = after + 1;
        eventSequence <= end;
        eventSequence++
      ) {
        final entry = source[(eventSequence - 1) % source.length] as Map;
        events.add({
          'sequence': eventSequence,
          'kind': eventSequence == 1 ? 'baseline' : 'command_write',
          'attribution': entry['attribution'],
          'receipt': entry['receipt'],
        });
      }
      await _reply(request, 200, {
        'schemaVersion': 1,
        'ref': history['complete']['response']['ref'],
        'chainId': eventChainId,
        'headSequence': eventHead,
        'events': events,
        'nextAfter': end < eventHead ? end : null,
        'verified': true,
      });
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

final class _EventCheckpointMemory implements CoreHaEventCheckpointBackend {
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
  final eventCheckpointBackend = _EventCheckpointMemory();
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
      eventCheckpointStore: CoreHaEventCheckpointStore(
        backend: eventCheckpointBackend,
      ),
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
    'real Core HTTP rule history binds actor rule service command and result',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      journey.fixture.serveRuleAttribution();
      try {
        await journey.start();
        final entry = journey.controller!.entries.first;
        expect(entry.attribution.source, CoreHaAttributionSource.coreRule);
        expect(
          entry.attribution.reason,
          CoreHaAttributionReason.explicitRuleExecution,
        );
        expect(entry.attribution.correlationId, entry.receipt.requestId);
        expect(entry.attribution.executionId, entry.receipt.requestId);
        expect(entry.attribution.ruleId, '3' * 32);
        expect(entry.attribution.ruleRevision, 4);
        expect(entry.attribution.serviceId, '2' * 32);
        expect(entry.attribution.serviceRevision, 1);
        expect(entry.receipt.actorId, 'f' * 32);
        expect(entry.receipt.action, CoreHaCommandAction.turnOn);
        expect(entry.receipt.dispatchState, CoreHaDispatchState.accepted);
        expect(journey.fixture.historyReads, 1);
        expect(journey.network.blocked, 0);
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'real Core HTTP never elevates explicit or unknown history to a rule',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      journey.fixture
        ..serveRuleAttribution()
        ..appendUnknownAttribution();
      try {
        await journey.start();
        final entries = journey.controller!.entries;
        expect(entries.map((entry) => entry.attribution.source), [
          CoreHaAttributionSource.coreRule,
          CoreHaAttributionSource.coreApi,
          CoreHaAttributionSource.unknown,
        ]);
        expect(entries.first.attribution.ruleId, '3' * 32);
        for (final entry in entries.skip(1)) {
          expect(entry.attribution.ruleId, isNull);
          expect(entry.attribution.ruleRevision, isNull);
          expect(entry.attribution.executionId, isNull);
        }
        expect(
          entries.last.attribution.reason,
          CoreHaAttributionReason.unknown,
        );
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'offline and late authority change never make retained rule proof current',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      journey.fixture.serveRuleAttribution();
      try {
        await journey.start();
        final controller = journey.controller!;
        expect(controller.entries.first.attribution.ruleId, '3' * 32);
        expect(controller.stale, isFalse);
        expect(controller.eventTrustCurrent, isTrue);

        journey.fixture.historyStatus = 503;
        await journey.refresh();
        expect(controller.entries.first.attribution.ruleId, '3' * 32);
        expect(controller.stale, isTrue);
        expect(controller.eventTrustCurrent, isFalse);

        journey.fixture.historyStatus = 200;
        journey.fixture.historyGate = Completer<void>();
        final reads = journey.fixture.historyReads;
        final pending = journey.refresh();
        while (journey.fixture.historyReads == reads) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        journey.current = false;
        journey.owner.value++;
        controller.setVisible(false);
        journey.fixture.historyGate!.complete();
        await pending;
        expect(controller.entries, isEmpty);
        expect(controller.stale, isFalse);
        expect(controller.eventTrustCurrent, isFalse);
        expect(controller.verification, isNull);
      } finally {
        await journey.close();
      }
    },
  );

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

  test(
    'event cursor survives controller restart and only advances after proof',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        expect(journey.eventCheckpointBackend.writes, 1);
        expect(journey.fixture.eventAfter, [null]);

        journey.controller!.dispose();
        journey.fixture.advance();
        journey.controller = CoreHaActivityController(
          journey.home,
          journey.target,
          journey.api,
          DateTime.now,
          () => journey.current,
          journey.owner,
          verifyIntegrity: true,
          checkpointStore: CoreHaCheckpointStore(
            backend: journey.checkpointBackend,
          ),
          eventCheckpointStore: CoreHaEventCheckpointStore(
            backend: journey.eventCheckpointBackend,
          ),
          checkpointProtected: true,
        )..setVisible(true);
        await journey.settle();

        expect(journey.fixture.eventAfter.last, 2);
        expect(journey.controller!.eventHeadSequence, 3);
        expect(journey.eventCheckpointBackend.writes, 2);
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'failed refresh revokes current trust but retains the persisted cursor',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        expect(journey.controller!.eventTrustCurrent, isTrue);
        expect(journey.eventCheckpointBackend.writes, 1);
        journey.fixture.eventStatus = 503;
        await journey.refresh();
        expect(journey.controller!.eventTrustCurrent, isFalse);
        expect(journey.controller!.eventChainId, isNull);
        expect(journey.eventCheckpointBackend.writes, 1);

        journey.fixture
          ..eventStatus = 200
          ..advance();
        await journey.refresh();
        expect(journey.fixture.eventAfter.last, 2);
        expect(journey.controller!.eventTrustCurrent, isTrue);
        expect(journey.controller!.eventHeadSequence, 3);
        expect(journey.eventCheckpointBackend.writes, 2);
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'event trust rejects chain replacement, rollback, and failed refresh',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        final controller = journey.controller!;
        expect(controller.eventTrustCurrent, isTrue);
        expect(controller.eventChainId, 'e' * 32);
        expect(controller.eventHeadSequence, 2);

        journey.fixture.eventChainId = 'f' * 32;
        await journey.refresh();
        expect(controller.eventTrustCurrent, isFalse);
        expect(controller.eventChainId, isNull);

        journey.fixture.eventChainId = 'e' * 32;
        await journey.refresh();
        expect(controller.eventTrustCurrent, isTrue);
        journey.fixture.eventHead = 1;
        await journey.refresh();
        expect(controller.eventTrustCurrent, isFalse);

        journey.fixture.eventHead = 2;
        await journey.refresh();
        expect(controller.eventTrustCurrent, isTrue);
        journey.fixture.eventStatus = 503;
        await journey.refresh();
        expect(controller.eventTrustCurrent, isFalse);
        expect(controller.eventChainId, isNull);
      } finally {
        await journey.close();
      }
    },
  );

  test(
    'account, home, and late responses erase retained event trust',
    () async {
      final journey = _Journey(await _HistoryCoreFixture.start());
      try {
        await journey.start();
        final controller = journey.controller!;
        expect(controller.eventTrustCurrent, isTrue);
        final writes = journey.eventCheckpointBackend.writes;
        journey.fixture.eventGate = Completer<void>();
        final before = journey.fixture.eventReads;
        final pending = controller.refresh();
        while (journey.fixture.eventReads <= before) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await journey.account.signOut();
        expect(controller.eventTrustCurrent, isFalse);
        journey.fixture.eventGate!.complete();
        await pending;
        expect(controller.eventTrustCurrent, isFalse);
        expect(controller.eventChainId, isNull);
        expect(controller.entries, isEmpty);
        expect(journey.eventCheckpointBackend.writes, writes);
      } finally {
        await journey.close();
      }

      final homeChange = _Journey(await _HistoryCoreFixture.start());
      try {
        await homeChange.start();
        expect(homeChange.controller!.eventTrustCurrent, isTrue);
        await homeChange.home.choose(HomeSource.directLocal);
        expect(homeChange.controller!.eventTrustCurrent, isFalse);
        expect(homeChange.controller!.eventChainId, isNull);
      } finally {
        await homeChange.close();
      }
    },
  );
}
