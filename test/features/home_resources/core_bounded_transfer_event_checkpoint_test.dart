import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_controller.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_file_access.dart';
import 'package:larenor/features/home_resources/data/core_bounded_transfer_event_checkpoint.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

final class _MemoryBackend implements CoreBoundedEventCheckpointBackend {
  final values = <String, String>{};
  int writes = 0;
  Future<void> Function()? afterRead;

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    await afterRead?.call();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }
}

HomeResourcePage _page() {
  final fixture = contract();
  return HomeResourcePage.fromJson(
    fixture['memberList'],
    expectedContext: ServerContext.fromJson(fixture['context']),
  );
}

Map<String, Object> _receipt({String state = 'completed'}) => {
  'requestId': 'c' * 32,
  'traceId': 'c' * 32,
  'state': state,
  'contentLength': 16,
  'sha256': 'd' * 64,
  'contentType': 'text/plain',
  'serviceRevision': 1,
  'createdAt': 10.0,
  'updatedAt': state == 'accepted' ? 10.0 : 11.0,
};

Map<String, Object?> _events(
  HomeResourceRecord target, {
  String chain = 'e',
  String proof = 'a',
  String actor = '9',
  int head = 2,
  int? after,
}) => {
  'schemaVersion': 1,
  'ref': {
    'schemaVersion': 1,
    'coreId': target.context.coreId,
    'homeId': target.context.homeId,
    'kind': 'resource',
    'id': target.id,
  },
  'chainId': chain * 32,
  'headSequence': head,
  'cursorCheckpoint': after == 2 ? proof * 64 : '0' * 64,
  'pageCheckpoint': proof * 64,
  'headCheckpoint': proof * 64,
  'events': after == 2
      ? <Object>[]
      : [
          {
            'sequence': 1,
            'kind': 'accepted',
            'actorId': actor * 32,
            'receipt': _receipt(state: 'accepted'),
          },
          {
            'sequence': 2,
            'kind': 'result',
            'actorId': actor * 32,
            'receipt': _receipt(),
          },
        ],
  'nextAfter': null,
  'verified': true,
};

void main() {
  test('event API binds target, cursor, sequence, and receipt state', () async {
    final target = _page().entries.last;
    final requests = <http.Request>[];
    final api = CoreBoundedDownloadApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(_events(target, after: 2)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    final page = await api.eventHistory(
      token: 'fixture-token',
      target: target,
      after: 2,
      limit: 50,
    );

    expect(requests.single.url.queryParameters, {'after': '2', 'limit': '50'});
    expect(page.chainId, 'e' * 32);
    expect(page.headSequence, 2);
    expect(page.events, isEmpty);
    expect(page.nextAfter, isNull);

    final baselineApi = CoreBoundedDownloadApi(
      endpoint: ServerEndpoint('https://core.invalid'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            ..._events(target, head: 1),
            'events': [
              {
                'sequence': 1,
                'kind': 'baseline',
                'actorId': '9' * 32,
                'receipt': _receipt(state: 'accepted'),
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(baselineApi.close);

    final baseline = await baselineApi.eventHistory(
      token: 'fixture-token',
      target: target,
    );
    expect(baseline.headSequence, 1);
    expect(baseline.events.single.kind, CoreBoundedTransferEventKind.baseline);
    expect(
      baseline.events.single.receipt.state,
      CoreBoundedTransferState.accepted,
    );

    for (final mutation
        in <Map<String, Object?> Function(Map<String, Object?>)>{
          (value) => {...value, 'chainId': 'bad'},
          (value) => {...value, 'headCheckpoint': 'bad'},
          (value) => {...value, 'pageCheckpoint': 'b' * 64},
          (value) => {
            ...value,
            'ref': {...value['ref'] as Map, 'id': 'f' * 32},
          },
          (value) => {
            ...value,
            'events': [
              {
                'sequence': 1,
                'kind': 'result',
                'actorId': '9' * 32,
                'receipt': _receipt(state: 'accepted'),
              },
            ],
          },
        }) {
      final bad = CoreBoundedDownloadApi(
        endpoint: ServerEndpoint('https://core.invalid'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(mutation(_events(target))),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await expectLater(
        bad.eventHistory(token: 'fixture-token', target: target),
        throwsA(
          isA<CoreBoundedDownloadException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      bad.close();
    }
  });

  test('checkpoint is scope-bound and rejects rollback, replacement, and retirement', () async {
    final target = _page().entries.last;
    final backend = _MemoryBackend();
    final store = CoreBoundedEventCheckpointStore(
      backend: backend,
      clock: () => DateTime.utc(2026, 9, 20, 12),
    );
    final scope = CoreBoundedEventCheckpointScope(
      context: target.context,
      resourceId: target.id,
      actorId: '9' * 32,
      role: ServerRole.member,
    );
    final first = await store.advance(
      scope,
      before: null,
      chainId: 'e' * 32,
      headSequence: 2,
      headCheckpoint: 'a' * 64,
      isCurrent: () => true,
    );
    expect(await store.read(scope, isCurrent: () => true), first);
    expect(backend.writes, 1);

    for (final proof in [('e' * 32, 1), ('f' * 32, 3)]) {
      await expectLater(
        store.advance(
          scope,
          before: first,
          chainId: proof.$1,
          headSequence: proof.$2,
          headCheckpoint: 'a' * 64,
          isCurrent: () => true,
        ),
        throwsA(isA<CoreBoundedEventCheckpointException>()),
      );
    }
    expect(backend.writes, 1);
    await expectLater(
      store.advance(
        scope,
        before: first,
        chainId: 'e' * 32,
        headSequence: 2,
        headCheckpoint: 'b' * 64,
        isCurrent: () => true,
      ),
      throwsA(
        isA<CoreBoundedEventCheckpointException>().having(
          (error) => error.code,
          'code',
          'rollback',
        ),
      ),
    );
    expect(backend.writes, 1);

    var current = true;
    backend.afterRead = () async => current = false;
    await expectLater(
      store.read(scope, isCurrent: () => current),
      throwsA(
        isA<CoreBoundedEventCheckpointException>().having(
          (error) => error.code,
          'code',
          'retired',
        ),
      ),
    );
    expect(backend.writes, 1);
  });

  testWidgets('v1 checkpoint blocks rollback before verified v2 migration', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester);
    await harness.signIn();
    await flush(tester);
    final target = _page().entries.last;
    final backend = _MemoryBackend();
    final scope = CoreBoundedEventCheckpointScope(
      context: target.context,
      resourceId: target.id,
      actorId: '9' * 32,
      role: ServerRole.member,
    );
    final identity = jsonEncode([
      scope.context.coreId,
      scope.context.homeId,
      scope.resourceId,
      scope.actorId,
      scope.role.name,
    ]);
    final legacyKey =
        'core_bounded_event_checkpoint_v1_${sha256.convert(utf8.encode(identity))}';
    backend.values[legacyKey] = jsonEncode({
      'version': 1,
      ...scope.toJson(),
      'chainId': 'e' * 32,
      'headSequence': 2,
      'verifiedAt': '2026-09-20T12:00:00.000Z',
      'revision': 4,
    });
    var head = 1;
    final cursors = <int?>[];
    final store = CoreBoundedEventCheckpointStore(backend: backend);
    final controller = CoreBoundedDownloadController(
      harness.home(tester),
      (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/transfers/events')) {
            final after = int.tryParse(
              request.url.queryParameters['after'] ?? '',
            );
            cursors.add(after);
            if (head == 1 && after == 2) {
              return http.Response(
                '{"error":{"code":"revision_conflict"}}',
                409,
                headers: {'content-type': 'application/json'},
              );
            }
            final response = _events(
              target,
              head: head,
              after: after,
              actor: '9',
            );
            if (head == 1 && after == null) {
              response['events'] = [
                {
                  'sequence': 1,
                  'kind': 'result',
                  'actorId': '9' * 32,
                  'receipt': _receipt(),
                },
              ];
            }
            return http.Response(
              jsonEncode(response),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'receipts': [_receipt()],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
      CoreBoundedDownloadFileAccess(),
      () => harness.now,
      () => true,
      null,
      store,
    )..setVisible(true);
    addTearDown(controller.dispose);

    await tester.runAsync(
      () => controller.loadHistory(target, isCurrent: () => true),
    );
    expect(cursors, [2]);
    expect(controller.historyPhase, CoreBoundedHistoryPhase.changed);
    expect(controller.historyTrusted, isFalse);
    expect(backend.writes, 0);
    final currentKey = CoreBoundedEventCheckpointStore.storageKey(scope);
    expect(backend.values.keys, isNot(contains(currentKey)));

    head = 2;
    await tester.runAsync(
      () => controller.loadHistory(target, isCurrent: () => true),
    );
    expect(cursors, [2, 2]);
    expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
    expect(controller.historyTrusted, isTrue);
    expect(backend.writes, 1);
    final migrated = jsonDecode(backend.values[currentKey]!);
    expect(migrated['version'], 2);
    expect(migrated['chainId'], 'e' * 32);
    expect(migrated['headSequence'], 2);
    expect(migrated['headCheckpoint'], 'a' * 64);
    expect(migrated['revision'], 5);
  });

  testWidgets(
    'history trust resumes at checkpoint and failed proof is never current',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final target = _page().entries.last;
      final backend = _MemoryBackend();
      final store = CoreBoundedEventCheckpointStore(backend: backend);
      var chain = 'e';
      var proof = 'a';
      var eventActor = '8';
      var eventStatus = 200;
      final cursors = <int?>[];

      CoreBoundedDownloadController build() => CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/transfers/events')) {
              final after = int.tryParse(
                request.url.queryParameters['after'] ?? '',
              );
              cursors.add(after);
              return http.Response(
                eventStatus == 200
                    ? jsonEncode(
                        _events(
                          target,
                          chain: chain,
                          proof: proof,
                          actor: eventActor,
                          after: after,
                        ),
                      )
                    : '{"error":{"code":"server_unavailable","message":"private"}}',
                eventStatus,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({
                'receipts': [_receipt()],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        CoreBoundedDownloadFileAccess(),
        () => harness.now,
        () => true,
        null,
        store,
      )..setVisible(true);

      var controller = build();
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.failed);
      expect(controller.historyTrusted, isFalse);
      expect(backend.writes, 0);

      eventActor = '9';
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
      expect(controller.historyTrusted, isTrue);
      expect(controller.historyChainId, 'e' * 32);
      expect(controller.historyHeadSequence, 2);
      expect(cursors, [null, null]);
      expect(backend.writes, 1);

      proof = 'b';
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.changed);
      expect(controller.historyTrusted, isFalse);
      expect(backend.writes, 1);
      proof = 'a';

      controller.dispose();
      controller = build();
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );
      expect(cursors.last, 2);
      expect(controller.historyTrusted, isTrue);
      expect(backend.writes, 1);

      chain = 'f';
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.changed);
      expect(controller.history, isEmpty);
      expect(controller.historyTrusted, isFalse);
      expect(backend.writes, 1);

      chain = 'e';
      eventStatus = 503;
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.failed);
      expect(controller.historyTrusted, isFalse);
      expect(backend.writes, 1);
    },
  );
}
