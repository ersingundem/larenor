import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/inventory/data/inventory_api.dart';
import 'package:larenor/features/inventory/data/inventory_controller.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const room = '44444444444444444444444444444444';
const device = '55555555555555555555555555555555';
const document = '66666666666666666666666666666666';
const actor = '77777777777777777777777777777777';
const subject = '88888888888888888888888888888888';

Map<String, Object?> item(String id) => {
  'item': {
    'schemaVersion': 1,
    'ref': {
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
      'kind': 'inventory_item',
      'id': id,
    },
    'revision': 1,
    'label': 'Item ${id.substring(0, 2)}',
    'links': {
      'schemaVersion': 1,
      'roomId': room,
      'deviceId': device,
      'documentIds': [document],
    },
  },
};

final class SocketHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().fold<List<int>>(
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
      'content-length': '${body.length}',
    };
    socket.write('${request.method} $target HTTP/1.1\r\n');
    for (final entry in headers.entries) {
      socket.write('${entry.key}: ${entry.value}\r\n');
    }
    socket.write('\r\n');
    socket.add(body);
    await socket.flush();
    final receive = socket.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final abort = request is http.AbortableRequest
        ? request.abortTrigger
        : null;
    final raw = abort == null
        ? await receive
        : await Future.any<List<int>>([
            receive,
            abort.then<List<int>>((_) {
              socket.destroy();
              throw http.RequestAbortedException(request.url);
            }),
          ]);
    final delimiter = utf8.encode('\r\n\r\n');
    var split = -1;
    for (var i = 0; i <= raw.length - delimiter.length; i++) {
      if (raw[i] == 13 &&
          raw[i + 1] == 10 &&
          raw[i + 2] == 13 &&
          raw[i + 3] == 10) {
        split = i;
        break;
      }
    }
    if (split < 0) throw const FormatException('Invalid HTTP response.');
    final head = utf8.decode(raw.sublist(0, split)).split('\r\n');
    final status = int.parse(head.first.split(' ')[1]);
    final responseHeaders = <String, String>{};
    for (final line in head.skip(1)) {
      final index = line.indexOf(':');
      if (index > 0) {
        responseHeaders[line.substring(0, index).toLowerCase()] = line
            .substring(index + 1)
            .trim();
      }
    }
    return http.StreamedResponse(
      Stream.value(raw.sublist(split + 4)),
      status,
      headers: responseHeaders,
      request: request,
    );
  }
}

final class IsolatedInventoryCore {
  late final HttpServer server;
  final requests = <({String method, String path, String body})>[];
  final delayed = Completer<void>();
  final delayedSeen = Completer<void>();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        method: request.method,
        path: request.uri.path,
        body: body,
      ));
      final id = request.uri.path.endsWith('/qr/resolve')
          ? ((jsonDecode(body) as Map)['value'] as String).split(':').last
          : request.uri.path.split('/').reversed.elementAt(1);
      if (id == 'f' * 32) {
        if (!delayedSeen.isCompleted) delayedSeen.complete();
        await delayed.future;
        final client = await request.response.detachSocket();
        client.destroy();
        continue;
      }
      final Object response;
      if (request.uri.path.endsWith('/qr/resolve')) {
        response = item(id);
      } else if (request.uri.path.endsWith('/history')) {
        response = {
          'schemaVersion': 1,
          'verified': true,
          'entries': [
            {
              'schemaVersion': 1,
              'sequence': 1,
              'action': 'create',
              'actorId': actor,
              'itemRevision': 1,
              'createdAt': 1788609600.0,
            },
          ],
        };
      } else if (request.uri.path.endsWith('/grants')) {
        response = {
          'schemaVersion': 1,
          'itemRevision': 1,
          'grants': [
            {'schemaVersion': 1, 'subjectId': subject},
          ],
        };
      } else {
        request.response.statusCode = 404;
        response = {
          'error': {'code': 'not_found'},
        };
      }
      final encoded = utf8.encode(jsonEncode(response));
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    }
  }

  Future<void> close() async {
    if (!delayed.isCompleted) delayed.complete();
    await server.close(force: true);
  }
}

void main() {
  test('real HTTP resolve builds bounded list/detail/grants/history with zero mutator', () async {
    final coreHost = IsolatedInventoryCore();
    await coreHost.start();
    addTearDown(coreHost.close);
    final context = ServerContext.fromJson({
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
    });
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint(coreHost.baseUrl),
      timeout: const Duration(seconds: 2),
      client: SocketHttpClient(),
    );
    addTearDown(transport.close);
    final controller = InventoryController(
      gateway: InventoryApi(transport, 'read-token', context),
      context: context,
      canReadGrants: true,
      isCurrent: () => true,
      maximumEntries: 2,
    );

    for (final id in ['a' * 32, 'b' * 32, 'c' * 32]) {
      await controller.resolveManual('larenor:inventory:v1:$core:$home:$id');
    }
    expect(controller.entries.map((entry) => entry.item.id), [
      'c' * 32,
      'b' * 32,
    ]);
    expect(controller.selected?.grants?.subjectIds, [subject]);
    expect(controller.selected?.history.verified, isTrue);
    expect(controller.selected?.item.links.documentIds, [document]);
    expect(coreHost.requests, hasLength(9));
    expect(
      coreHost.requests.every(
        (r) =>
            r.method == 'GET' ||
            r.method == 'POST' && r.path.endsWith('/qr/resolve'),
      ),
      isTrue,
    );
    expect(coreHost.requests.any((r) => r.path.contains('/admin/')), isFalse);

    final before = coreHost.requests.length;
    await controller.resolveManual(
      'larenor:inventory:v1:$core:$home:${'d' * 33}',
    );
    expect(coreHost.requests, hasLength(before));
  });

  test(
    'closing real transport cancels late read and retains zero evidence',
    () async {
      final coreHost = IsolatedInventoryCore();
      await coreHost.start();
      addTearDown(coreHost.close);
      final context = ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': core,
        'homeId': home,
      });
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint(coreHost.baseUrl),
        timeout: const Duration(seconds: 2),
        client: SocketHttpClient(),
      );
      final controller = InventoryController(
        gateway: InventoryApi(transport, 'read-token', context),
        context: context,
        canReadGrants: true,
        isCurrent: () => true,
      );
      final read = controller.resolveManual(
        'larenor:inventory:v1:$core:$home:${'f' * 32}',
      );
      await coreHost.delayedSeen.future.timeout(const Duration(seconds: 2));
      controller.retire();
      transport.close();
      coreHost.delayed.complete();
      await read;
      expect(controller.entries, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.failure, InventoryFailure.stale);
    },
  );
}
