import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/meal_planner/data/weekly_meal_plan_api.dart';
import 'package:larenor/features/meal_planner/domain/weekly_meal_plan.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '1a111111111111111111111111111111';
const home = '2b222222222222222222222222222222';
const accountId = '3c333333333333333333333333333333';
const family = '4d444444444444444444444444444444';
const person = '5e555555555555555555555555555555';
const recipe = '6f666666666666666666666666666666';
const entry = '7a777777777777777777777777777777';
const requestId = '8b888888888888888888888888888888';

Map<String, Object?> authority(int revision) => {
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
  'accountId': accountId,
  'sessionFamilyId': family,
  'accountRevision': 4,
  'planRevision': revision,
};

Map<String, Object?> emptyResponse() => {
  'authority': authority(0),
  'plan': null,
};

Map<String, Object?> planFrom(Map<String, dynamic> body, int revision) => {
  'authority': authority(revision),
  'plan': {
    'schemaVersion': 1,
    'revision': revision,
    'weekStart': body['weekStart'],
    'recipes': body['recipes'],
    'entries': body['entries'],
  },
};

final class SocketHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final socket = await Socket.connect(request.url.host, request.url.port);
    final target = request.url.hasQuery
        ? '${request.url.path}?${request.url.query}'
        : request.url.path;
    final headers = <String, String>{
      ...request.headers,
      'host': request.url.authority,
      'connection': 'close',
      'content-length': '${bytes.length}',
    };
    socket.write('${request.method} $target HTTP/1.1\r\n');
    for (final value in headers.entries) {
      socket.write('${value.key}: ${value.value}\r\n');
    }
    socket.write('\r\n');
    socket.add(bytes);
    await socket.flush();
    final raw = await socket.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final delimiter = utf8.encode('\r\n\r\n');
    var split = -1;
    for (var index = 0; index <= raw.length - delimiter.length; index++) {
      if (raw[index] == 13 &&
          raw[index + 1] == 10 &&
          raw[index + 2] == 13 &&
          raw[index + 3] == 10) {
        split = index;
        break;
      }
    }
    if (split < 0) throw const FormatException('invalid HTTP response');
    final head = utf8.decode(raw.sublist(0, split)).split('\r\n');
    final responseHeaders = <String, String>{};
    for (final line in head.skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        responseHeaders[line.substring(0, separator).toLowerCase()] = line
            .substring(separator + 1)
            .trim();
      }
    }
    return http.StreamedResponse(
      Stream.value(raw.sublist(split + delimiter.length)),
      int.parse(head.first.split(' ')[1]),
      headers: responseHeaders,
      request: request,
    );
  }
}

final class IsolatedMealCore {
  late final HttpServer server;
  final requests = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, Object?>>{};
  Map<String, Object?> current = emptyResponse();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(bodyText) as Map);
      requests.add({
        'method': request.method,
        'path': request.uri.path,
        'body': body,
      });
      Object response = current;
      var status = 200;
      if (request.method == 'PUT') {
        final id = body['requestId'] as String;
        final encoded = jsonEncode(body);
        final receipt = receipts[id];
        if (receipt != null) {
          if (receipt['request'] != encoded) {
            status = 409;
            response = {
              'error': {'code': 'idempotency_conflict'},
            };
          } else {
            response = receipt['response']!;
          }
        } else {
          final revision =
              (current['authority']! as Map)['planRevision'] as int;
          response = planFrom(body, revision + 1);
          current = response as Map<String, Object?>;
          receipts[id] = {'request': encoded, 'response': response};
        }
      }
      final encoded = utf8.encode(jsonEncode(response));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    }
  }

  Future<void> close() => server.close(force: true);
}

final class MemorySessions implements ServerSessionPersistence {
  MemorySessions(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

Map<String, Object?> userResponse() => {
  'user': {
    'id': accountId,
    'username': 'ece',
    'role': 'member',
    'mustChangePassword': false,
  },
};

void main() {
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
  });

  test(
    'real HTTP persists Turkish weekly menu and replays one exact request',
    () async {
      final coreHost = IsolatedMealCore();
      await coreHost.start();
      addTearDown(coreHost.close);
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint(coreHost.baseUrl),
        client: SocketHttpClient(),
      );
      addTearDown(transport.close);
      final api = WeeklyMealPlanApi(transport, 'bounded-token', context);
      final base = await api.read();
      final recipeValue = MealRecipe.fromJson({
        'schemaVersion': 1,
        'id': recipe,
        'locale': 'tr',
        'title': 'Mercimek çorbası',
        'baseServings': 2,
        'ingredients': [
          {
            'schemaVersion': 1,
            'quantityMillis': 200000,
            'unit': 'g',
            'name': 'Mercimek',
          },
        ],
      });
      final entryValue = MealPlanEntry.fromJson({
        'schemaVersion': 1,
        'id': entry,
        'date': '2026-09-21',
        'slot': 'dinner',
        'recipeId': recipe,
        'servings': 5,
        'personId': person,
        'expectedPersonRevision': 2,
        'expectedPersonAclRevision': 3,
      });

      Future<WeeklyMealPlanSnapshot> save() => api.save(
        base: base,
        requestId: requestId,
        weekStart: '2026-09-21',
        recipes: [recipeValue],
        entries: [entryValue],
      );
      final first = await save();
      final replay = await save();
      final editedEntry = MealPlanEntry.fromJson({
        'schemaVersion': 1,
        'id': entry,
        'date': '2026-09-21',
        'slot': 'dinner',
        'recipeId': recipe,
        'servings': 6,
        'personId': person,
        'expectedPersonRevision': 2,
        'expectedPersonAclRevision': 3,
      });
      final edited = await api.save(
        base: first,
        requestId: '9' * 32,
        weekStart: first.plan!.weekStart,
        recipes: first.plan!.recipes,
        entries: [editedEntry],
      );

      expect(
        first.plan!.recipeFor(first.plan!.entries.single).title,
        'Mercimek çorbası',
      );
      expect(first.plan!.entries.single.servings, 5);
      expect(
        first.plan!
            .recipeFor(first.plan!.entries.single)
            .shoppingDraft(first.plan!.entries.single.servings)
            .shoppingSummaries('tr'),
        ['500 g Mercimek'],
      );
      expect(replay.authority.planRevision, first.authority.planRevision);
      expect(edited.authority.planRevision, 2);
      expect(edited.plan!.entries.single.servings, 6);
      expect(coreHost.requests.map((value) => value['method']), [
        'GET',
        'PUT',
        'PUT',
        'PUT',
      ]);
      expect((coreHost.requests.last['body']! as Map)['expectedRevision'], 1);
      expect(
        (coreHost.requests.last['body']! as Map)['expectedAccountRevision'],
        4,
      );
    },
  );

  test(
    'account, route and lifecycle invalidation rejects a late Core result',
    () async {
      final delayed = Completer<http.Response>();
      late final ServerAccountController account;
      final endpoint = ServerEndpoint('https://core.test');
      final stored = ServerSession(
        endpoint: endpoint,
        accessToken: 'valid-access-token-000000000000',
        refreshToken: 'valid-refresh-token-00000000000',
        expiresAt: DateTime.utc(2026, 9, 21, 18),
        user: ServerUser(
          id: accountId,
          username: 'ece',
          role: ServerRole.member,
          mustChangePassword: false,
        ),
        context: context,
      );
      LarenorServerApi factory(ServerEndpoint value) => LarenorServerApi(
        endpoint: value,
        clock: () => DateTime.utc(2026, 9, 21, 12),
        client: MockClient((request) {
          if (request.url.path.endsWith('/auth/me')) {
            return Future.value(
              http.Response(
                jsonEncode(userResponse()),
                200,
                headers: {'content-type': 'application/json'},
              ),
            );
          }
          if (request.url.path.endsWith('/context')) {
            return Future.value(
              http.Response(
                jsonEncode(context.toJson()),
                200,
                headers: {'content-type': 'application/json'},
              ),
            );
          }
          return delayed.future;
        }),
      );
      account = ServerAccountController(
        store: MemorySessions(stored),
        apiFactory: factory,
        clock: () => DateTime.utc(2026, 9, 21, 12),
      );
      addTearDown(account.dispose);
      await account.initialize();
      var current = true;
      final gateway = WeeklyMealPlanAccountGateway(
        account: account,
        context: context,
        isCurrent: () => current,
        apiFactory: factory,
      );
      addTearDown(gateway.close);
      final pending = gateway.read();
      current = false;
      delayed.complete(
        http.Response(
          jsonEncode(emptyResponse()),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await expectLater(
        pending,
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
  );

  test('malformed Core scope and unsupported units fail closed', () {
    final wrongScope = emptyResponse();
    wrongScope['authority'] = {...authority(0), 'homeId': 'f' * 32};
    expect(
      () => WeeklyMealPlanSnapshot.fromJson(wrongScope, context),
      throwsA(isA<LarenorServerException>()),
    );
    expect(
      () => MealIngredient.fromJson({
        'schemaVersion': 1,
        'quantityMillis': 1000,
        'unit': 'cup',
        'name': 'Mercimek',
      }),
      throwsA(isA<LarenorServerException>()),
    );
  });
}
