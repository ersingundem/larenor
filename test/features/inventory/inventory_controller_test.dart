import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/inventory/data/inventory_api.dart';
import 'package:larenor/features/inventory/data/inventory_controller.dart';
import 'package:larenor/features/inventory/domain/inventory_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'inventory_models_test.dart';

final class FakeInventoryGateway implements InventoryGateway {
  FakeInventoryGateway({this.delay, this.failure});
  final Completer<InventoryItem>? delay;
  Object? failure;
  int resolves = 0, histories = 0, grantReads = 0;

  @override
  Future<InventoryItem> resolve(InventoryQr qr) async {
    resolves++;
    if (failure != null) throw failure!;
    if (delay != null) return delay!.future;
    return InventoryItem.fromResponse(itemResponse(), expected: context);
  }

  @override
  Future<InventoryHistory> history(InventoryItem item) async {
    histories++;
    return InventoryHistory.fromResponse(historyResponse(), expectedItem: item);
  }

  @override
  Future<InventoryGrants> grants(InventoryItem item) async {
    grantReads++;
    return InventoryGrants.fromResponse(grantsResponse(), expectedItem: item);
  }
}

void main() {
  test(
    'read gateway calls only scoped resolve, history and grant endpoints',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        final body = switch (request.url.path) {
          final path when path.endsWith('/qr/resolve') => itemResponse(),
          final path when path.endsWith('/history') => historyResponse(),
          final path when path.endsWith('/grants') => grantsResponse(),
          _ => throw StateError('unexpected path'),
        };
        return http.Response(
          jsonEncode(body),
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
      final qr = InventoryQr.parse('larenor:inventory:v1:$core:$home:$itemId');
      final item = await api.resolve(qr);
      await api.history(item);
      await api.grants(item);
      expect(requests.map((request) => request.method), ['POST', 'GET', 'GET']);
      expect(
        requests.every(
          (request) => request.headers['authorization'] == 'Bearer token',
        ),
        isTrue,
      );
      expect(requests.map((request) => request.url.path), [
        '/api/v1/inventory/$core/$home/qr/resolve',
        '/api/v1/inventory/$core/$home/items/$itemId/history',
        '/api/v1/inventory/$core/$home/items/$itemId/grants',
      ]);
    },
  );

  test(
    'scan and manual entry resolve one current scoped read-only detail',
    () async {
      final gateway = FakeInventoryGateway();
      final controller = InventoryController(
        gateway: gateway,
        context: context,
        canReadGrants: true,
        isCurrent: () => true,
      );
      final qr = 'larenor:inventory:v1:$core:$home:$itemId';
      await controller.resolveScanned(qr);
      await controller.resolveManual(qr);
      expect(
        (gateway.resolves, gateway.histories, gateway.grantReads),
        (2, 2, 2),
      );
      expect(controller.entries, hasLength(1));
      expect(controller.selected?.item.label, 'Kahve değirmeni');
      expect(controller.selected?.history.verified, isTrue);
      expect(controller.failure, isNull);
    },
  );

  test(
    'malformed foreign offline and late results fail closed without followups',
    () async {
      var current = true;
      final delayed = Completer<InventoryItem>();
      final gateway = FakeInventoryGateway(delay: delayed);
      final controller = InventoryController(
        gateway: gateway,
        context: context,
        canReadGrants: true,
        isCurrent: () => current,
      );
      await controller.resolveManual('broken');
      await controller.resolveScanned(
        'larenor:inventory:v1:$core:${'9' * 32}:$itemId',
      );
      expect(gateway.resolves, 0);

      final operation = controller.resolveScanned(
        'larenor:inventory:v1:$core:$home:$itemId',
      );
      current = false;
      controller.retire();
      delayed.complete(
        InventoryItem.fromResponse(itemResponse(), expected: context),
      );
      await operation;
      expect(controller.entries, isEmpty);
      expect((gateway.histories, gateway.grantReads), (0, 0));

      final offline = InventoryController(
        gateway: FakeInventoryGateway(
          failure: const LarenorServerException('connection_failed'),
        ),
        context: context,
        canReadGrants: false,
        isCurrent: () => true,
      );
      await offline.resolveManual('larenor:inventory:v1:$core:$home:$itemId');
      expect(offline.entries, isEmpty);
      expect(offline.failure, InventoryFailure.offline);

      final retainedGateway = FakeInventoryGateway();
      final retained = InventoryController(
        gateway: retainedGateway,
        context: context,
        canReadGrants: false,
        isCurrent: () => true,
      );
      await retained.resolveManual('larenor:inventory:v1:$core:$home:$itemId');
      expect(retained.entries, hasLength(1));
      retainedGateway.failure = const LarenorServerException(
        'connection_failed',
      );
      await retained.resolveManual('larenor:inventory:v1:$core:$home:$itemId');
      expect(retained.entries, isEmpty);
      expect(retained.selected, isNull);
      expect(retained.failure, InventoryFailure.offline);
    },
  );
}
