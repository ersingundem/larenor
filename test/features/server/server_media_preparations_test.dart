import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_preparations/data/server_media_preparations_api.dart';
import 'package:larenor/features/server/media_preparations/data/server_media_preparations_controller.dart';
import 'package:larenor/features/server/media_preparations/domain/server_media_preparation_models.dart';

import 'server_media_preparations_test_support.dart';

void main() {
  final invalid = throwsA(isA<LarenorServerException>().having(
    (e) => e.code, 'code', 'invalid_response',
  ));
  test('actual Server contract is immutable preparation metadata only', () {
    for (final cancelled in [false, true]) {
      final record = ServerMediaPreparation.fromJson(mediaPreparationJson(cancelled: cancelled));
      expect(record.prepared, !cancelled);
      expect(record.plan.components, hasLength(6));
      expect(record.plan.installAvailable, isFalse);
      expect(() => record.plan.components.clear(), throwsUnsupportedError);
      expect(record.plan.components.last.plan.integrationRole, 'internal_engine');
    }
  });
  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'secret field': (r) => r['token'] = 'synthetic-secret',
    'unknown state': (r) => r['state'] = 'installed',
    'float revision': (r) => r['revision'] = 1.0,
    'bad state revision': (r) => r['revision'] = 2,
    'unsafe id': (r) => r['id'] = '../another',
    'non boolean catalog': (r) => r['catalogCurrent'] = 1,
    'invalid calendar': (r) => r['createdAt'] = '2026-02-30T00:00:00.000Z',
    'reverse timestamps': (r) => r['updatedAt'] = '2020-01-01T00:00:00.000Z',
    'install enabled': (r) => r['plan']['installAvailable'] = true,
    'bootstrap verified': (r) => r['plan']['bootstrapExposure'] = 'verified',
    'plan wrong preparation': (r) => r['plan']['preparationId'] = 'f' * 32,
    'missing component': (r) => r['plan']['components'].removeLast(),
    'reordered component': (r) {
      final c = r['plan']['components'];
      final first = c[0]; c[0] = c[1]; c[1] = first;
    },
    'component wrong platform': (r) => r['plan']['components'][0]['plan']['image']['platform'] = 'linux/arm64',
    'component wrong catalog': (r) => r['plan']['components'][0]['plan']['catalogDigest'] = 'f' * 64,
    'resource total mismatch': (r) => r['plan']['requestedResources']['memoryMiB'] = 1,
  }.entries) {
    test('record rejects ${mutation.key}', () {
      final record = mediaPreparationJson();
      mutation.value(record);
      expect(() => ServerMediaPreparation.fromJson(record), invalid);
    });
  }
  group('guarded durable preparations', () {
    late MediaPreparationsFixture f;
    late ServerMediaPreparationsController controller;
    setUp(() async {
      f = MediaPreparationsFixture();
      await f.account.initialize();
      controller = ServerMediaPreparationsController(f.account, requestId: () => mediaFixtureJson()['createRequest']['requestId']);
    });
    tearDown(() { controller.dispose(); f.account.dispose(); });
    Future<void> create() async {
      await controller.prepareDraft(current: () => true);
      await controller.create(platform: 'linux/amd64', settings: MediaPreparationSettings.fromJson(mediaFixtureJson()['createRequest']['settings']), current: () => true);
    }
    test('open history is independent of context catalog and worker; no auto writes', () async {
      f.records.add(mediaPreparationJson()..['catalogCurrent'] = false);
      f.respond = (r) async => r.url.path.endsWith('/media/preparations') ? f.pluginResponse(r) : f.json({}, 503);
      await controller.load(current: () => true);
      expect(controller.preparations.single.catalogCurrent, isFalse);
      expect(f.mutations, isEmpty);
      expect(f.adminCalls.map((r) => r.url.path), ['/prefix/api/v1/admin/media/preparations']);
    });
    test('explicit create then a fresh controller recovers the Server record and cancels with revision', () async {
      await controller.load(current: () => true);
      expect(f.mutations, isEmpty);
      await create();
      expect(controller.selected!.prepared, isTrue);
      expect(jsonDecode(f.mutations.single.body), mediaFixtureJson()['createRequest']);
      controller.dispose();
      controller = ServerMediaPreparationsController(f.account);
      await controller.load(current: () => true);
      await controller.select(controller.preparations.single, current: () => true);
      await controller.cancelSelected(current: () => true);
      expect(controller.selected!.prepared, isFalse);
      expect(jsonDecode(f.mutations.last.body), {'expectedRevision': 1});
      expect(f.calls.any((r) => RegExp(r'/(jobs|install|previews|check)(/|$)').hasMatch(r.url.path)), isFalse);
    });
    for (final outcome in ['connection_failed', 'server_error', 'invalid_response']) {
      test('$outcome after a committed create retries manually with the exact same request', () async {
        var writes = 0;
        f.respond = (r) async {
          final response = f.pluginResponse(r);
          if (r.method == 'POST' && r.url.path.endsWith('/preparations') && ++writes == 1) {
            if (outcome == 'connection_failed') throw http.ClientException('synthetic-secret');
            return outcome == 'server_error' ? http.Response('synthetic-secret', 502) : f.json({'secret': 'synthetic-secret'}, 201);
          }
          return response;
        };
        await create();
        expect(controller.canRetryCreate, isTrue);
        expect(f.records, hasLength(1));
        await controller.create(platform: 'linux/amd64', settings: MediaPreparationSettings.fromJson(mediaFixtureJson()['createRequest']['settings']), current: () => true);
        expect(writes, 1);
        await controller.retryCreate(current: () => true);
        expect(writes, 2);
        expect(f.mutations.last.body, f.mutations.first.body);
        expect(f.records, hasLength(1));
        expect(controller.selected, isNotNull);
      });
    }
    test('hidden delayed create cannot expose a record or retain retry authority', () async {
      final held = Completer<http.Response>();
      f.respond = (r) => r.method == 'POST' ? held.future : Future.value(f.pluginResponse(r));
      final creating = create();
      while (f.mutations.isEmpty) { await Future<void>.delayed(Duration.zero); }
      controller.invalidate();
      held.complete(f.json({'preparation': mediaPreparationJson()}, 201));
      await creating;
      expect(controller.selected, isNull);
      expect(controller.canRetryCreate, isFalse);
      expect(controller.preparations, isEmpty);
    });
    test('single flight suppresses duplicate list and create while busy', () async {
      final held = Completer<http.Response>();
      f.respond = (_) => held.future;
      final loading = controller.load(current: () => true);
      await Future<void>.delayed(Duration.zero);
      await controller.load(current: () => true);
      expect(f.adminCalls, hasLength(1));
      held.complete(f.json({'preparations': [], 'nextBefore': null}));
      await loading;
    });
    test('API rejects oversized duplicate and nonprogressing pages and mismatched IDs', () async {
      await f.account.withSession((api, session) async {
        final media = ServerMediaPreparationsApi(api, session.accessToken);
        for (final payload in [
          {'preparations': List.generate(11, (_) => mediaPreparationJson()), 'nextBefore': null},
          {'preparations': [mediaPreparationJson(), mediaPreparationJson()], 'nextBefore': null},
          {'preparations': [mediaPreparationJson()], 'nextBefore': 5},
          {'preparations': [], 'nextBefore': 1},
        ]) {
          f.respond = (_) async => f.json(payload);
          await expectLater(media.list(before: 5), invalid);
        }
        f.respond = (_) async => f.json({'preparation': mediaPreparationJson()});
        await expectLater(media.get('f' * 32), invalid);
      });
    });
  });
}
