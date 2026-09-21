import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/family_board/data/family_board_api.dart';
import 'package:larenor/features/family_board/domain/family_board_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'family_board_controller_test.dart';

void main() {
  test('authority bootstrap binds only the exact Core account and route', () {
    final value = FamilyBoardBinding.fromAuthority(
      {
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
        'homeRevision': 7,
        'boardId': boardId,
        'accountId': account,
        'accountRevision': 3,
        'memberRevision': 1,
        'sessionFamilyId': session,
        'role': 'admin',
        'canRead': true,
        'canWrite': true,
        'active': true,
      },
      coreId: core,
      homeId: home,
      accountId: account,
      routeRevision: 11,
      lifecycleRevision: 13,
    );
    expect(value, binding());
    expect(
      () => FamilyBoardBinding.fromAuthority(
        {
          ...value.serverAuthority,
          'role': 'admin',
          'canRead': true,
          'canWrite': true,
          'active': true,
          'memberRevision': 2,
        },
        coreId: core,
        homeId: home,
        accountId: account,
        routeRevision: 11,
        lifecycleRevision: 13,
      ),
      returnsNormally,
    );
    expect(
      () => FamilyBoardBinding.fromAuthority(
        {
          ...value.serverAuthority,
          'role': 'admin',
          'canRead': true,
          'canWrite': true,
          'active': true,
          'homeId': 'f' * 32,
        },
        coreId: core,
        homeId: home,
        accountId: account,
        routeRevision: 11,
        lifecycleRevision: 13,
      ),
      throwsA(isA<FamilyBoardException>()),
    );
  });

  test('Core transport sends exact authority and performs no retry', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final response = switch (request.url.path) {
        final path when path.endsWith('/delta') => {
          ...(() {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final after = body['afterSequence'] as int;
            return <String, Object?>{
              'schemaVersion': 1,
              'coreId': core,
              'homeId': home,
              'boardId': boardId,
              'boardRevision': 1,
              'afterSequence': after,
              'nextAfter': 1,
              'auditHead': 'a' * 64,
              'events': after == 1
                  ? <Object?>[]
                  : [
                      {
                        'schemaVersion': 1,
                        'sequence': 1,
                        'action': 'append',
                        'actorId': account,
                        'elementId': cardId,
                        'boardRevision': 1,
                        'createdAt': 17.0,
                        'previousHash': '0' * 64,
                        'eventHash': 'a' * 64,
                      },
                    ],
            };
          })(),
        },
        final path when path.endsWith('/commands') => {
          'schemaVersion': 1,
          'requestId': '8' * 32,
          'boardId': boardId,
          'boardRevision': 2,
          'auditSequence': 2,
          'action': 'update',
          'elementId': cardId,
        },
        _ => snapshotJson(),
      };
      return http.Response(
        jsonEncode(response),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.example'),
      client: client,
    );
    addTearDown(transport.close);
    final api = FamilyBoardApi(transport, 'secret-token', binding());
    await api.read(binding());
    await api.delta(binding(), afterSequence: 0);
    await api.delta(binding(), afterSequence: 1);
    final command = FamilyBoardCommand.update(
      '8' * 32,
      1,
      BoardCard(id: cardId, text: 'Güncel', x: 20, y: 30, color: 'yellow'),
    );
    await api.mutate(binding(), command);
    expect(requests, hasLength(4));
    expect(requests.map((request) => request.method), [
      'GET',
      'POST',
      'POST',
      'POST',
    ]);
    expect(
      requests.every(
        (request) => request.headers['authorization'] == 'Bearer secret-token',
      ),
      isTrue,
    );
    final mutation = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(mutation['expectedHomeRevision'], 7);
    expect(mutation['expectedAccountRevision'], 3);
    expect(mutation['expectedMemberRevision'], 1);
    expect(mutation['expectedSessionFamilyId'], session);
    expect(mutation['expectedBoardRevision'], 1);
  });

  test('foreign or stale binding dispatches no request', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{}', 200);
    });
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.example'),
      client: client,
    );
    addTearDown(transport.close);
    final api = FamilyBoardApi(transport, 'secret-token', binding());
    await expectLater(
      api.read(binding(memberRevision: 2)),
      throwsA(isA<FamilyBoardException>()),
    );
    await expectLater(
      api.read(binding(active: false)),
      throwsA(isA<FamilyBoardException>()),
    );
    expect(requests, 0);
  });

  test('revision-zero empty-board delta is a valid bounded response', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'schemaVersion': 1,
          'coreId': core,
          'homeId': home,
          'boardId': boardId,
          'boardRevision': 0,
          'afterSequence': 0,
          'nextAfter': 0,
          'auditHead': '0' * 64,
          'events': <Object?>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.example'),
      client: client,
    );
    addTearDown(transport.close);
    final value = await FamilyBoardApi(
      transport,
      'secret-token',
      binding(),
    ).delta(binding(), afterSequence: 0);
    expect(value.boardRevision, 0);
    expect(value.events, isEmpty);
  });
}
