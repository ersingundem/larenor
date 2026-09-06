import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../integration_test/support/home_people_contract_fixture.dart';
import '../../integration_test/support/synthetic_core_account.dart';
import '../../integration_test/support/synthetic_core_people_account.dart';
import '../../integration_test/support/synthetic_ha_server.dart';

void main() {
  late SyntheticHaServer host;
  late SyntheticCorePeopleAccount account;
  late HttpClient client;
  final contract =
      jsonDecode(homePeopleContractFixture) as Map<String, dynamic>;

  setUp(() async {
    host = await SyntheticHaServer.start();
    account = SyntheticCorePeopleAccount();
    host.coreAccount = account;
    client = FixtureNetwork(host.port).createHttpClient(null);
  });
  tearDown(() async {
    expect(host.requests, 0);
    expect(host.acceptedActions, isEmpty);
    client.close(force: true);
    await host.close();
  });
  Future<(int, Map<String, dynamic>?)> request(
    String path, {
    String method = 'GET',
    String? token = SyntheticCoreAccount.accessToken,
    Object? body,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('${host.baseUrl}/api/v1$path'),
    );
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (
      response.statusCode,
      text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  Future<void> login() async {
    final response = await request(
      '/auth/login',
      method: 'POST',
      token: null,
      body: {
        'username': SyntheticCoreAccount.username,
        'password': SyntheticCoreAccount.password,
        'deviceName': 'Synthetic tablet',
      },
    );
    expect(response.$1, 200);
    expect(response.$2!['user']['id'], contract['subjectId']);
    expect(response.$2!['user']['role'], 'member');
  }

  String path() => '/home-people/${account.coreId}/${account.homeId}';

  test(
    'embedded Android people contract is identical to real Server artifact',
    () {
      expect(
        contract,
        jsonDecode(File('contracts/home-people.v1.json').readAsStringSync()),
      );
    },
  );
  test('people fixture is opt-in and does not change ordinary account role or resource page', () async {
    host.coreAccount = SyntheticCoreAccount();
    final login = await request(
      '/auth/login',
      method: 'POST',
      body: {
        'username': SyntheticCoreAccount.username,
        'password': SyntheticCoreAccount.password,
        'deviceName': 'Synthetic tablet',
      },
    );
    expect(login.$2!['user']['role'], 'admin');
    expect(login.$2!['user']['id'], 'fixture-core-user-id');
    expect((await request(path())).$1, 403);
    expect(
      (await request('/home-resources/${account.coreId}/${account.homeId}'))
          .$2!['entries'],
      isEmpty,
    );
  });
  test('member login and read use exact real typed Server response', () async {
    await login();
    final response = await request(path());
    expect(response.$1, 200);
    expect(response.$2, contract['memberList']['response']);
    final page = HomePeoplePage.fromJson(
      response.$2,
      expectedContext: ServerContext.fromJson(contract['context']),
    );
    expect(page.entries.map((p) => p.label), ['Deniz Öztürk', '🌿' * 80]);
    expect(page.entries.every((p) => !p.canWrite), isTrue);
    expect(account.peopleReads, 1);
    expect(account.requestedPeopleScopes, [('a' * 32, 'b' * 32)]);
  });
  test(
    'read token is not valid before fixture login and wrong token stays denied',
    () async {
      expect((await request(path())).$1, 401);
      await login();
      expect((await request(path(), token: null)).$1, 401);
      expect((await request(path(), token: 'synthetic-wrong')).$1, 401);
      expect(account.peopleReads, 0);
    },
  );
  test('bounded cursor pages match actual Server responses exactly', () async {
    await login();
    final first = (await request('${path()}?limit=1')).$2!;
    expect(first, contract['firstPage']['response']);
    final second = await request(
      '${path()}?limit=1&after=${first['nextAfter']}&expectedSnapshot=${first['snapshot']}',
    );
    expect(second.$2, contract['secondPage']['response']);
    expect(account.peopleReads, 2);
  });
  test('explicit empty view retires old paging snapshot and returns real empty member response', () async {
    await login();
    final first = (await request('${path()}?limit=1')).$2!;
    account.view = SyntheticCorePeopleView.empty;
    expect(
      (await request(
        '${path()}?limit=1&after=${first['nextAfter']}&expectedSnapshot=${first['snapshot']}',
      )).$1,
      409,
    );
    expect((await request(path())).$2, contract['emptyMember']['response']);
    account.view = SyntheticCorePeopleView.member;
    expect((await request(path())).$2, contract['memberList']['response']);
  });
  test('foreign context never discloses original household and original context can be restored', () async {
    await login();
    final original = path();
    account.coreId = 'c' * 32;
    account.homeId = 'd' * 32;
    expect((await request(original)).$1, 404);
    final other = await request(path());
    expect(other.$1, 404);
    expect(jsonEncode(other.$2), isNot(contains('Deniz')));
    account.coreId = 'a' * 32;
    account.homeId = 'b' * 32;
    expect((await request(path())).$2, contract['memberList']['response']);
  });
  for (final query in [
    '?limit=0',
    '?limit=101',
    '?limit=01',
    '?limit=-1',
    '?limit=1&limit=2',
    '?after=${'1' * 32}',
    '?expectedSnapshot=${'g' * 64}',
    '?token=synthetic',
    '?expectedSnapshot=${'a' * 64}&expectedSnapshot=${'b' * 64}',
    '?limit=1%0A',
    '?after=${'1' * 32}%0A&expectedSnapshot=${'a' * 64}',
  ]) {
    test('invalid query $query is rejected without people read', () async {
      await login();
      expect((await request('${path()}$query')).$1, 400);
      expect(account.peopleReads, 0);
    });
  }
  test('nonexistent cursor and stale snapshot do not count as reads', () async {
    await login();
    final token = contract['memberList']['response']['snapshot'];
    expect(
      (await request('${path()}?after=${'9' * 32}&expectedSnapshot=$token')).$1,
      404,
    );
    expect((await request('${path()}?expectedSnapshot=${'a' * 64}')).$1, 409);
    expect(account.peopleReads, 0);
  });
  test(
    'no mutation, item, grant or auth bypass endpoint exists in read fixture',
    () async {
      await login();
      for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
        expect(
          (await request(
            path(),
            method: method,
            body: {'label': 'do not create'},
          )).$1,
          403,
        );
      }
      expect(
        (await request(
          '/admin${path()}',
          method: 'POST',
          body: {'label': 'do not create'},
        )).$1,
        403,
      );
      expect((await request('${path()}/${'1' * 32}')).$1, 404);
      expect((await request('/admin${path()}/${'1' * 32}/grants')).$1, 403);
      expect(account.peopleReads, 0);
    },
  );
  test('member fixture retains empty existing resource endpoint without HA activity', () async {
    await login();
    final reply = await request(
      '/home-resources/${account.coreId}/${account.homeId}',
    );
    expect(reply.$1, 200);
    expect(reply.$2!['entries'], isEmpty);
    expect(account.peopleReads, 0);
  });
  test(
    'duplicate authorization values cannot grant fixture read access',
    () async {
      await login();
      final call = await client.getUrl(
        Uri.parse('${host.baseUrl}/api/v1${path()}'),
      );
      call.headers.add(
        'authorization',
        'Bearer ${SyntheticCoreAccount.accessToken}',
      );
      call.headers.add(
        'authorization',
        'Bearer ${SyntheticCoreAccount.accessToken}',
      );
      final response = await call.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
      expect(account.peopleReads, 0);
    },
  );
}
