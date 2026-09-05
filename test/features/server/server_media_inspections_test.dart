import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_preparations/domain/server_media_preparation_models.dart';
import 'package:larenor/features/server/media_preparations/domain/server_media_inspection_models.dart';
import 'package:larenor/features/server/media_preparations/data/server_media_inspections_api.dart';
import 'package:larenor/features/server/media_preparations/data/server_media_inspections_controller.dart';

import 'server_media_inspections_test_support.dart';
import 'server_media_preparations_test_support.dart';

void main() {
  final invalid = throwsA(
    isA<LarenorServerException>().having(
      (e) => e.code,
      'code',
      'invalid_response',
    ),
  );
  ServerMediaPreparation preparation() =>
      ServerMediaPreparation.fromJson(mediaPreparationJson());
  test('strict inspection states retain mixed requirements without installation claim', () {
    for (final state in [
      'queued',
      'running',
      'succeeded',
      'failed',
      'cancelled',
      'needs_attention',
    ]) {
      final record = ServerMediaInspection.fromJson(
        mediaInspectionJson(state: state),
      );
      expect(record.active, state == 'queued' || state == 'running');
      if (state == 'succeeded') {
        expect(
          record.result!.checks.where((c) => c.status == 'unknown'),
          hasLength(5),
        );
        expect(() => record.result!.checks.clear(), throwsUnsupportedError);
      }
    }
  });
  test('actual HTTP worker and restart fixture binds aggregate observations to the saved preparation', () {
    final fixture = jsonDecode(File('contracts/media-inspections.v1.json').readAsStringSync());
    final request = ServerMediaInspectionRequest(preparation(), fixture['createRequest']['requestId']);
    expect(request.toJson(), fixture['createRequest']);
    for (final key in ['queued', 'succeeded', 'queuedForCancel', 'cancelled']) {
      final inspection = ServerMediaInspection.fromJson(fixture[key]);
      expect(inspection.matchesPreparation(preparation()), isTrue);
      if (key == 'succeeded') {
        expect(request.accepts(inspection), isTrue);
        expect(inspection.result!.checks.where((c) => c.code.startsWith('daemon_')).map((c) => c.status), everyElement('unknown'));
        expect(inspection.result!.checks.any((c) => c.code == 'storage_capacity' && c.requiredMiB == 16384), isTrue);
      }
    }
    expect(ServerMediaInspectionCapabilities.fromJson(fixture['capabilities']).inspectionConfigured, isTrue);
  });
  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'secret': (r) => r['token'] = 'synthetic-secret',
    'missing nullable': (r) => r.remove('result'),
    'newline id': (r) => r['id'] = '${'a' * 32}\n',
    'wrong preparation revision': (r) => r['preparationRevision'] = 2,
    'float revision': (r) => r['revision'] = 1.0,
    'unknown state': (r) => r['state'] = 'installed',
    'unknown phase': (r) => r['phase'] = 'pulling',
    'reverse time': (r) => r['updatedAt'] = '2000-01-01T00:00:00.000Z',
    'invalid date': (r) => r['createdAt'] = '2026-02-30T00:00:00.000Z',
    'queued cancellation': (r) => r['cancelRequested'] = true,
    'queued error': (r) => r['errorCode'] = 'worker_unavailable',
    'queued result': (r) =>
        r['result'] = mediaInspectionJson(state: 'succeeded')['result'],
    'terminal phase': (r) {
      r['state'] = 'cancelled';
      r['cancelRequested'] = true;
    },
    'false success': (r) {
      r['state'] = 'succeeded';
      r['phase'] = 'complete';
    },
    'wrong attention error': (r) {
      r['state'] = 'needs_attention';
      r['phase'] = 'complete';
      r['errorCode'] = 'worker_unavailable';
    },
  }.entries) {
    test('inspection rejects ${mutation.key}', () {
      final value = mediaInspectionJson();
      mutation.value(value);
      expect(() => ServerMediaInspection.fromJson(value), invalid);
    });
  }
  test('inspection state revisions match the persisted Server transition contract', () {
    for (final value in [
      mediaInspectionJson(revision: 2),
      mediaInspectionJson(state: 'running', revision: 1),
      mediaInspectionJson(state: 'succeeded', revision: 1),
      mediaInspectionJson(state: 'running', revision: 0x7fffffffffffffff),
    ]) {expect(() => ServerMediaInspection.fromJson(value), invalid);}
  });
  test('result is bound to catalog, plan and platform but allows worker clock difference', () {
    for (final key in ['catalogDigest', 'planHash', 'platform']) {
      final value = mediaInspectionJson(state: 'succeeded');
      value['result'][key] = key == 'platform' ? 'linux/arm64' : 'f' * 64;
      expect(() => ServerMediaInspection.fromJson(value), invalid);
    }
    final value = mediaInspectionJson(state: 'succeeded');
    value['result']['checkedAt'] = '2026-09-05T08:59:00.000Z';
    expect(ServerMediaInspection.fromJson(value).result, isNotNull);
  });
  test('capabilities are strict configuration information only', () {
    expect(
      ServerMediaInspectionCapabilities.fromJson({
        'inspectionConfigured': false,
        'installAvailable': false,
      }).inspectionConfigured,
      isFalse,
    );
    for (final value in [
      {'inspectionConfigured': true, 'installAvailable': true},
      {'inspectionConfigured': 1, 'installAvailable': false},
      {
        'inspectionConfigured': true,
        'installAvailable': false,
        'socket': 'synthetic-secret',
      },
    ]) {
      expect(() => ServerMediaInspectionCapabilities.fromJson(value), invalid);
    }
  });
  group('durable inspection API and guarded controller', () {
    late MediaInspectionsFixture f;
    late ServerMediaInspectionsController c;
    setUp(() async {
      f = MediaInspectionsFixture();
      await f.account.initialize();
      c = ServerMediaInspectionsController(
        f.account,
        requestId: () => '2' * 32,
      );
    });
    tearDown(() {
      c.dispose();
      f.account.dispose();
    });
    Future<void> review() => c.review(preparation(), current: () => true);
    test('history reads independently of configured worker and survives new controller', () async {
      f.inspections.add(mediaInspectionJson(state: 'succeeded'));
      f.configured = false;
      await c.load(current: () => true);
      expect(c.inspections, hasLength(1));
      expect(f.calls.any((r) => r.url.path.endsWith('/capabilities')), isFalse);
      c.dispose();
      c = ServerMediaInspectionsController(f.account);
      await c.load(current: () => true);
      await review();
      expect(c.canLaunch, isFalse);
      expect(c.inspections, hasLength(1));
      expect(f.mutations, isEmpty);
    });
    test(
      'explicit launch sends the exact reviewed preparation revision and hash',
      () async {
        await c.load(current: () => true);
        await review();
        expect(f.mutations, isEmpty);
        expect(c.canLaunch, isTrue);
        await c.launch(current: () => true);
        expect(jsonDecode(f.mutations.single.body), {
          'requestId': '2' * 32,
          'preparationId': preparation().id,
          'expectedRevision': 1,
          'planHash': preparation().plan.planHash,
        });
        expect(c.selected!.coreId, preparation().plan.coreId);
        await c.launch(current: () => true);
        expect(f.mutations, hasLength(1));
        expect(
          f.calls.any(
            (r) =>
                RegExp(r'/(install|jobs|previews)(/|$)').hasMatch(r.url.path),
          ),
          isFalse,
        );
      },
    );
    for (final outcome in [
      'connection_failed',
      'server_error',
      'invalid_response',
    ]) {
      test(
        '$outcome after committed POST only recovers manually with the identical body',
        () async {
          await review();
          var writes = 0;
          f.respond = (r) async {
            final response = f.pluginResponse(r);
            if (r.method == 'POST' &&
                r.url.path.endsWith('/inspections') &&
                ++writes == 1) {
              if (outcome == 'connection_failed')
                throw http.ClientException('synthetic-secret');
              return outcome == 'server_error'
                  ? http.Response('synthetic-secret', 502)
                  : f.json({'token': 'synthetic-secret'}, 201);
            }
            return response;
          };
          await c.launch(current: () => true);
          expect(c.canRetryLaunch, isTrue);
          await c.launch(current: () => true);
          expect(writes, 1);
          await c.retryLaunch(current: () => true);
          expect(f.mutations.last.body, f.mutations.first.body);
          expect(f.inspections, hasLength(1));
          expect(c.selected, isNotNull);
        },
      );
    }
    test('historical or cancelled preparation cannot launch and review binds original identity', () async {
      for (final record in [
        mediaPreparationJson(cancelled: true),
        mediaPreparationJson()..['catalogCurrent'] = false,
      ]) {
        f.records
          ..clear()
          ..add(record);
        await review();
        expect(c.canLaunch, isFalse);
        await c.launch(current: () => true);
      }
      expect(f.mutations, isEmpty);
    });
    test(
      'page and later review reject another Core and retain prior history',
      () async {
        f.inspections.add(mediaInspectionJson());
        await c.load(current: () => true);
        final original = c.inspections.single;
        f.inspections.add(mediaInspectionJson(index: 2)..['homeId'] = 'e' * 32);
        await c.load(current: () => true);
        expect(c.failure, 'invalid_response');
        expect(c.inspections.single.id, original.id);
        f.respond = (r) async => r.url.path.endsWith('/context')
            ? f.json({
                'schemaVersion': 1,
                'coreId': 'd' * 32,
                'homeId': 'e' * 32,
              })
            : f.pluginResponse(r);
        await review();
        expect(c.failure, 'invalid_response');
        expect(c.canLaunch, isFalse);
      },
    );
    test('a preparation entry binds Core and home before any returned history can appear', () async {
      c.dispose();
      c = ServerMediaInspectionsController(f.account,
        context: ServerContext.fromJson(mediaFixtureJson()['context']));
      f.respond = (r) async => r.url.path.endsWith('/context')
          ? f.json({'schemaVersion': 1, 'coreId': 'd' * 32, 'homeId': 'e' * 32}) : f.pluginResponse(r);
      await c.load(current: () => true);
      expect(c.failure, 'invalid_response'); expect(c.inspections, isEmpty);
      expect(f.calls.any((r) => r.url.path.endsWith('/inspections')), isFalse);
    });
    test('cancel acknowledgement cannot retain an active uncancelled row', () async {
      final previous = ServerMediaInspection.fromJson(mediaInspectionJson());
      f.respond = (r) async => f.json({'inspection': mediaInspectionJson()});
      await expectLater(f.account.withSession((api, session) =>
        ServerMediaInspectionsApi(api, session.accessToken).cancel(previous)), invalid);
    });
    test('bounded pages reach all 256 records and reject duplicate or nondecreasing cursors', () async {
      f.inspections.addAll([
        for (var i = 1; i <= 256; i++)
          mediaInspectionJson(index: i, state: 'cancelled', revision: 2),
      ]);
      await c.load(current: () => true);
      while (c.nextBefore != null) {
        await c.loadMore(current: () => true);
      }
      expect(c.inspections, hasLength(256));
      expect(c.inspections.last.id, '0' * 31 + '1');
      f.respond = (r) async => f.json({
        'inspections': [mediaInspectionJson()],
        'nextBefore': 10,
      });
      await expectLater(
        f.account.withSession(
          (api, session) => ServerMediaInspectionsApi(
            api,
            session.accessToken,
          ).list(before: 10),
        ),
        invalid,
      );
    });
    test('stale account or route response cannot publish history or retain request authority', () async {
      final held = Completer<http.Response>();
      f.respond = (r) => r.url.path.endsWith('/inspections')
          ? held.future
          : Future.value(f.pluginResponse(r));
      final loading = c.load(current: () => true);
      while (!f.calls.any((r) => r.url.path.endsWith('/inspections'))) {
        await Future<void>.delayed(Duration.zero);
      }
      c.invalidate();
      held.complete(
        f.json({
          'inspections': [mediaInspectionJson()],
          'nextBefore': null,
        }),
      );
      await loading;
      expect(c.inspections, isEmpty);
      expect(c.selected, isNull);
    });
    test('cancel uses selected revision and uncertain cancellation needs fresh read', () async {
      f.inspections.add(mediaInspectionJson());
      await c.load(current: () => true);
      await c.select(c.inspections.single, current: () => true);
      f.respond = (r) async => r.url.path.endsWith('/cancel')
          ? f.json({
              'error': {'code': 'revision_conflict'},
            }, 409)
          : f.pluginResponse(r);
      await c.cancelSelected(current: () => true);
      expect(c.cancelNeedsRefresh, isTrue);
      await c.cancelSelected(current: () => true);
      expect(f.mutations, hasLength(1));
      f.respond = (r) async => f.pluginResponse(r);
      await c.refreshSelected(current: () => true);
      await c.cancelSelected(current: () => true);
      expect(jsonDecode(f.mutations.last.body), {'expectedRevision': 1});
      expect(c.selected!.state, 'cancelled');
    });
    test('fixed HTTP errors pass through only their matching status, arbitrary error text is redacted', () async {
      for (final pair in [
        ('media_inspection_conflict', 409),
        ('media_inspection_limit_reached', 409),
        ('media_preparation_changed', 409),
        ('media_inspection_storage_unavailable', 503),
      ]) {
        for (final status in [pair.$2, 502]) {
          f.respond = (_) async => f.json({
            'error': {'code': pair.$1, 'message': 'synthetic-secret'},
          }, status);
          await expectLater(
            f.account.withSession(
              (api, session) => api.request(
                'GET',
                '/admin/media/inspections',
                token: session.accessToken,
              ),
            ),
            throwsA(
              isA<LarenorServerException>().having(
                (e) => e.code,
                'code',
                status == pair.$2 ? pair.$1 : 'server_error',
              ),
            ),
          );
        }
      }
      f.respond = (_) async => f.json({
        'error': {'code': 'synthetic-secret'},
      }, 409);
      await expectLater(
        f.account.withSession(
          (api, session) => api.request(
            'GET',
            '/admin/media/inspections',
            token: session.accessToken,
          ),
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
    });
  });
}
