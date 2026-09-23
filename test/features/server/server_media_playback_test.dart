import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/media_playback/data/server_media_playback_api.dart';
import 'package:larenor/features/server/media_playback/data/server_media_playback_controller.dart';
import 'package:larenor/features/server/media_playback/domain/server_media_playback_models.dart';

import 'server_admin_test_support.dart';

const _intentId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _commandId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _installationId = '22222222222222222222222222222222';

Map<String, Object?> _pageJson() => {
  'schemaVersion': 1,
  'installationId': _installationId,
  'installationRevision': 7,
  'snapshotRevision': 9,
  'jellyfinServiceRevision': 11,
  'offset': 0,
  'nextOffset': null,
  'total': 1,
  'items': const [
    {
      'itemId': '33333333333333333333333333333333',
      'mediaKey': 'movie:tmdb:603',
      'title': 'The Matrix',
      'mediaKind': 'movie',
      'runtimeSeconds': 8160,
    },
  ],
};

Map<String, Object?> _intentJson() => {
  'requestId': _intentId,
  'installationId': _installationId,
  'expectedInstallationRevision': 7,
  'expectedSnapshotRevision': 9,
  'expectedJellyfinServiceRevision': 11,
  'itemId': '33333333333333333333333333333333',
  'mediaKey': 'movie:tmdb:603',
  'playbackRevision': 13,
  'expiresAt': 2000000000,
  'targets': const [
    {
      'targetId': 'living-room',
      'targetRevision': 5,
      'name': 'Living room',
      'available': true,
      'currentItemId': null,
      'positionSeconds': 0,
    },
  ],
};

Map<String, Object?> _receiptJson() => {
  'requestId': _commandId,
  'intentId': _intentId,
  'installationId': _installationId,
  'itemId': '33333333333333333333333333333333',
  'targetId': 'living-room',
  'playbackRevision': 14,
  'state': 'succeeded',
  'code': 'authenticated_readback',
  'installAvailable': false,
};

void main() {
  test('Core API binds catalog resource, intent, target and receipt', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.headers['authorization'], 'Bearer synthetic-access');
        if (request.url.path.endsWith('/intents')) {
          expect(body, {
            'requestId': _intentId,
            'installationId': _installationId,
            'expectedInstallationRevision': 7,
            'expectedSnapshotRevision': 9,
            'expectedJellyfinServiceRevision': 11,
            'itemId': '33333333333333333333333333333333',
            'mediaKey': 'movie:tmdb:603',
          });
          return http.Response(
            jsonEncode({'intent': _intentJson()}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(body, {
          'requestId': _commandId,
          'intentId': _intentId,
          'expectedPlaybackRevision': 13,
          'targetId': 'living-room',
          'expectedTargetRevision': 5,
          'startSeconds': 12,
        });
        return http.Response(
          jsonEncode({'receipt': _receiptJson()}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);
    final page = ServerMediaCatalogPage.fromJson(
      _pageJson(),
      query: 'matrix',
      mediaKind: ServerMediaCatalogKind.movie,
    );
    final client = ServerMediaPlaybackApi(
      api,
      'synthetic-access',
      requestId: () => calls.isEmpty ? _intentId : _commandId,
    );

    final intent = await client.prepare(page, page.items.single);
    final receipt = await client.play(
      intent,
      intent.targets.single,
      startSeconds: 12,
    );

    expect(receipt.state, ServerMediaPlaybackReceiptState.succeeded);
    expect(calls.map((call) => call.url.host).toSet(), {'core.test'});
    expect(calls.map((call) => call.url.path), [
      '/api/v1/media/playback/intents',
      '/api/v1/media/playback/commands',
    ]);
    expect(calls.map((call) => call.body).join(), isNot(contains('token')));
    expect(calls.map((call) => call.body).join(), isNot(contains('http')));
  });

  test('strict parser rejects secret fields and mismatched receipts', () {
    expect(
      () => ServerMediaPlaybackIntent.fromJson({
        ..._intentJson(),
        'accessToken': 'must-not-cross-boundary',
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMediaPlaybackReceipt.fromJson({
        ..._receiptJson(),
        'targetId': 'foreign-room',
      }, expectedRequestId: _commandId, expectedIntentId: _intentId,
          expectedInstallationId: _installationId,
          expectedItemId: '33333333333333333333333333333333',
          expectedTargetId: 'living-room', expectedPlaybackRevision: 13),
      throwsFormatException,
    );
  });

  test('controller retires delayed prepare and command results', () async {
    final fixture = AdminFixture();
    final prepare = Completer<http.Response>();
    final command = Completer<http.Response>();
    fixture.respond = (request) {
      if (request.url.path.endsWith('/intents')) return prepare.future;
      if (request.url.path.endsWith('/commands')) return command.future;
      return Future.value(fixture.defaultResponse(request));
    };
    await fixture.account.initialize();
    final controller = ServerMediaPlaybackController(
      fixture.account,
      requestId: () => _intentId,
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    final page = ServerMediaCatalogPage.fromJson(
      _pageJson(), query: 'matrix', mediaKind: null,
    );

    final pendingPrepare = controller.prepare(
      page,
      page.items.single,
      current: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    controller.retire();
    prepare.complete(fixture.json({'intent': _intentJson()}));
    await pendingPrepare;
    expect(controller.intent, isNull);

    await controller.prepare(
      page,
      page.items.single,
      current: () => true,
    );
    final pendingPlay = controller.play(
      controller.intent!.targets.single,
      current: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    command.complete(fixture.json({'receipt': _receiptJson()}, 201));
    await pendingPlay;
    expect(controller.receipt, isNull);
    expect(controller.intent, isNull);
  });

  test('throwing authority callback fails before Core request', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    final controller = ServerMediaPlaybackController(fixture.account);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    final page = ServerMediaCatalogPage.fromJson(
      _pageJson(), query: 'matrix', mediaKind: null,
    );
    final before = fixture.calls.length;
    await controller.prepare(
      page,
      page.items.single,
      current: () => throw StateError('stale route'),
    );
    expect(fixture.calls, hasLength(before));
    expect(controller.intent, isNull);
  });
}
