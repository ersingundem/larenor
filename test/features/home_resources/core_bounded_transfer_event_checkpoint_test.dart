import 'dart:async';
import 'dart:convert';

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
  'events': after == 2
      ? <Object>[]
      : [
          {
            'sequence': 1,
            'kind': 'accepted',
            'actorId': '9' * 32,
            'receipt': _receipt(state: 'accepted'),
          },
          {
            'sequence': 2,
            'kind': 'result',
            'actorId': '9' * 32,
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

    for (final mutation
        in <Map<String, Object?> Function(Map<String, Object?>)>{
          (value) => {...value, 'chainId': 'bad'},
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
          isCurrent: () => true,
        ),
        throwsA(isA<CoreBoundedEventCheckpointException>()),
      );
    }
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
                    ? jsonEncode(_events(target, chain: chain, after: after))
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
      expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
      expect(controller.historyTrusted, isTrue);
      expect(controller.historyChainId, 'e' * 32);
      expect(controller.historyHeadSequence, 2);
      expect(cursors, [null]);
      expect(backend.writes, 1);

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
