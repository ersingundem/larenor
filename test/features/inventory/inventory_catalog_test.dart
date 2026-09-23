import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/inventory/data/inventory_api.dart';
import 'package:larenor/features/inventory/data/inventory_catalog_controller.dart';
import 'package:larenor/features/inventory/domain/inventory_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'inventory_models_test.dart';

Map<String, Object?> pageResponse({
  List<Map<String, Object?>>? items,
  String? nextCursor,
}) => {
  'schemaVersion': 1,
  'verified': true,
  'items': items ?? [itemResponse()['item']! as Map<String, Object?>],
  'nextCursor': nextCursor,
};

final class _MemorySessions implements ServerSessionPersistence {
  _MemorySessions(this.value);
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

ServerSession _session() => ServerSession(
  endpoint: ServerEndpoint('https://core.example'),
  accessToken: 'valid-access-token-000000000000',
  refreshToken: 'valid-refresh-token-00000000000',
  expiresAt: DateTime.utc(2026, 9, 23, 18),
  user: ServerUser(
    id: '9' * 32,
    username: 'fixture',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  context: context,
);

http.Response _jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'account gateway contains throwing route authority before network',
    () async {
      var inventoryRequests = 0;
      LarenorServerApi factory(ServerEndpoint endpoint) => LarenorServerApi(
        endpoint: endpoint,
        clock: () => DateTime.utc(2026, 9, 23, 12),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/me')) {
            return _jsonResponse({
              'user': {
                'id': '9' * 32,
                'username': 'fixture',
                'role': 'admin',
                'mustChangePassword': false,
              },
            });
          }
          if (request.url.path.endsWith('/context')) {
            return _jsonResponse(context.toJson());
          }
          inventoryRequests++;
          return _jsonResponse(pageResponse());
        }),
      );
      final account = ServerAccountController(
        store: _MemorySessions(_session()),
        apiFactory: factory,
        clock: () => DateTime.utc(2026, 9, 23, 12),
      );
      addTearDown(account.dispose);
      await account.initialize();
      final gateway = InventoryAccountGateway(
        account: account,
        context: context,
        isCurrent: () => throw StateError('retired route'),
        apiFactory: factory,
      );
      addTearDown(gateway.close);

      await expectLater(
        gateway.list(),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(inventoryRequests, 0);
    },
  );

  test('account gateway rejects a page after route authority drifts', () async {
    final delayed = Completer<http.Response>();
    final requested = Completer<void>();
    var current = true;
    LarenorServerApi factory(ServerEndpoint endpoint) => LarenorServerApi(
      endpoint: endpoint,
      clock: () => DateTime.utc(2026, 9, 23, 12),
      client: MockClient((request) {
        if (request.url.path.endsWith('/auth/me')) {
          return Future.value(
            _jsonResponse({
              'user': {
                'id': '9' * 32,
                'username': 'fixture',
                'role': 'admin',
                'mustChangePassword': false,
              },
            }),
          );
        }
        if (request.url.path.endsWith('/context')) {
          return Future.value(_jsonResponse(context.toJson()));
        }
        if (!requested.isCompleted) requested.complete();
        return delayed.future;
      }),
    );
    final account = ServerAccountController(
      store: _MemorySessions(_session()),
      apiFactory: factory,
      clock: () => DateTime.utc(2026, 9, 23, 12),
    );
    addTearDown(account.dispose);
    await account.initialize();
    final gateway = InventoryAccountGateway(
      account: account,
      context: context,
      isCurrent: () => current,
      apiFactory: factory,
    );
    addTearDown(gateway.close);

    final result = gateway.list();
    await requested.future;
    current = false;
    delayed.complete(_jsonResponse(pageResponse()));
    await expectLater(
      result,
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
  });

  test('catalog page is strict bounded scoped and duplicate free', () {
    final page = InventoryPage.fromResponse(
      pageResponse(nextCursor: 'cursor'),
      expected: context,
    );
    expect(page.items.single.id, itemId);
    expect(page.nextCursor, 'cursor');
    expect(page.verified, isTrue);

    expect(
      () => InventoryPage.fromResponse(
        pageResponse(
          items: [
            itemResponse()['item']! as Map<String, Object?>,
            itemResponse()['item']! as Map<String, Object?>,
          ],
        ),
        expected: context,
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('catalog API sends only bounded GET page requests', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode(pageResponse(nextCursor: null)),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.example'),
      client: client,
    );
    addTearDown(transport.close);
    final api = InventoryApi(transport, 'token', context);
    final page = await api.list(limit: 25, cursor: 'opaque');
    expect(page.items, hasLength(1));
    expect(requests.single.method, 'GET');
    expect(
      requests.single.url.toString(),
      'https://core.example/api/v1/inventory/$core/$home/items?limit=25&cursor=opaque',
    );
    expect(requests.single.headers['authorization'], 'Bearer token');
    expect(() => api.list(limit: 0), throwsArgumentError);
    expect(() => api.list(limit: 101), throwsArgumentError);
  });

  test(
    'catalog controller rejects duplicate and retired page results',
    () async {
      final delayed = Completer<InventoryPage>();
      final gateway = _CatalogGateway(delayed.future);
      var current = true;
      final controller = InventoryCatalogController(
        gateway: gateway,
        isCurrent: () => current,
      );
      final operation = controller.refresh();
      current = false;
      controller.retire();
      delayed.complete(
        InventoryPage.fromResponse(pageResponse(), expected: context),
      );
      await operation;
      expect(controller.items, isEmpty);
      expect(controller.failure, InventoryCatalogFailure.stale);

      final first = InventoryPage.fromResponse(
        pageResponse(nextCursor: 'next'),
        expected: context,
      );
      final duplicate = InventoryPage.fromResponse(
        pageResponse(),
        expected: context,
      );
      final live = InventoryCatalogController(
        gateway: _SequenceCatalogGateway([first, duplicate]),
        isCurrent: () => true,
      );
      await live.refresh();
      expect(live.items, hasLength(1));
      await live.loadNext();
      expect(live.items, isEmpty);
      expect(live.failure, InventoryCatalogFailure.invalidResponse);
    },
  );
}

final class _CatalogGateway implements InventoryCatalogGateway {
  _CatalogGateway(this.result);
  final Future<InventoryPage> result;
  @override
  Future<InventoryPage> list({int limit = 25, String? cursor}) => result;
}

final class _SequenceCatalogGateway implements InventoryCatalogGateway {
  _SequenceCatalogGateway(this.pages);
  final List<InventoryPage> pages;
  var index = 0;
  @override
  Future<InventoryPage> list({int limit = 25, String? cursor}) async =>
      pages[index++];
}
