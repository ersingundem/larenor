import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/workshop/data/workshop_api.dart';
import 'package:larenor/features/workshop/domain/workshop_models.dart';

ServerContext context() => ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
});

ServerSession session() => ServerSession(
  endpoint: ServerEndpoint('https://core.invalid'),
  accessToken: 'x' * 43,
  refreshToken: 'y' * 43,
  expiresAt: DateTime.utc(2026, 10),
  context: context(),
  user: ServerUser(
    id: 'c' * 32,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
);

Map<String, Object?> printerJson({
  String connectivity = 'online',
  String thermal = 'normal',
  String filament = 'available',
  String door = 'closed',
  String emergency = 'clear',
  String freshness = 'current',
  List<String> actions = const ['pause', 'cancel'],
}) => {
  'schemaVersion': 1,
  'ref': {...context().toJson(), 'kind': 'workshop_printer', 'id': 'd' * 32},
  'revision': 4,
  'name': 'Workshop printer',
  'serviceRef': {'id': 'e' * 32, 'revision': 3},
  'job': {
    'revision': 7,
    'jobId': 'f' * 32,
    'state': 'printing',
    'progressPermille': 420,
    'remainingSeconds': 900,
  },
  'material': {'revision': 5, 'kind': 'pla', 'remainingGrams': 280.0},
  'safety': {
    'revision': 9,
    'connectivity': connectivity,
    'thermal': thermal,
    'filament': filament,
    'door': door,
    'emergency': emergency,
    'observedAt': 1788609600.0,
    'freshness': freshness,
  },
  'availableActions': actions,
};

Map<String, Object?> previewJson() => {
  'preview': {
    'schemaVersion': 1,
    'id': '1' * 32,
    'printerRef': {
      ...context().toJson(),
      'kind': 'workshop_printer',
      'id': 'd' * 32,
    },
    'action': 'pause',
    'confirmationToken': 't' * 43,
    'expiresAt': 1788609660.0,
  },
};

Map<String, Object?> receiptJson() => {
  'receipt': {
    'schemaVersion': 1,
    'id': '2' * 32,
    'sequence': 1,
    'printerRef': {
      ...context().toJson(),
      'kind': 'workshop_printer',
      'id': 'd' * 32,
    },
    'action': 'pause',
    'state': 'recorded',
    'effect': 'notDispatched',
    'authority': {
      'printerRevision': 4,
      'serviceRevision': 3,
      'jobRevision': 7,
      'materialRevision': 5,
      'safetyRevision': 9,
    },
    'createdAt': 1788609601.0,
  },
};

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'typed API keeps exact scope and sends only bounded action fields',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: session().endpoint,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer ${'x' * 43}');
          if (request.method == 'GET' &&
              request.url.path.endsWith('/printers')) {
            return response({
              'schemaVersion': 1,
              'printers': [printerJson()],
            });
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/intents')) {
            return response({
              'schemaVersion': 1,
              'intents': [receiptJson()['receipt']],
            });
          }
          if (request.url.path.endsWith('/previews')) {
            return response(previewJson(), 201);
          }
          return response(receiptJson(), 201);
        }),
      );
      addTearDown(transport.close);
      final api = WorkshopApi(transport, session(), isCurrent: () => true);
      final printers = await api.load();
      final printer = printers.single;
      final preview = await api.preview(
        printer: printer,
        action: WorkshopAction.pause,
        requestKey: 'pause-request-key-0001',
      );
      final receipt = await api.confirm(preview);

      expect(receipt.effect, WorkshopIntentEffect.notDispatched);
      expect(requests, hasLength(4));
      final previewBody = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(previewBody, {
        'schemaVersion': 1,
        'expectedPrinterRevision': 4,
        'expectedServiceRevision': 3,
        'expectedJobRevision': 7,
        'expectedMaterialRevision': 5,
        'expectedSafetyRevision': 9,
        'requestKey': 'pause-request-key-0001',
        'action': 'pause',
      });
      final wire = requests.map((request) => request.body).join();
      for (final forbidden in ['gcode', 'path', 'credential', 'apiKey']) {
        expect(wire.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
      }
      expect(requests.last.method, 'GET');
      expect(requests.last.url.queryParameters, {'limit': '100'});
    },
  );

  test('confirmation fails closed when receipt readback is missing', () async {
    final transport = LarenorServerApi(
      endpoint: session().endpoint,
      client: MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/printers')) {
          return response({
            'schemaVersion': 1,
            'printers': [printerJson()],
          });
        }
        if (request.method == 'GET') {
          return response({'schemaVersion': 1, 'intents': []});
        }
        if (request.url.path.endsWith('/previews')) {
          return response(previewJson(), 201);
        }
        return response(receiptJson(), 201);
      }),
    );
    addTearDown(transport.close);
    final api = WorkshopApi(transport, session(), isCurrent: () => true);
    final printer = (await api.load()).single;
    final preview = await api.preview(
      printer: printer,
      action: WorkshopAction.pause,
      requestKey: 'pause-request-key-0002',
    );
    await expectLater(
      api.confirm(preview),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('foreign, secret-bearing or unsafe action projections fail closed', () {
    for (final mutation
        in <Map<String, Object?> Function(Map<String, Object?>)>[
          (value) => {...value, 'gcode': 'M112'},
          (value) => {
            ...value,
            'ref': {
              ...value['ref']! as Map<String, Object?>,
              'homeId': '0' * 32,
            },
          },
          (value) => {
            ...value,
            'credentials': {'apiKey': 'secret'},
          },
          (value) => {
            ...value,
            'safety': {
              ...value['safety']! as Map<String, Object?>,
              'connectivity': 'offline',
            },
          },
        ]) {
      expect(
        () => WorkshopPrinter.fromJson(mutation(printerJson()), context()),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
}
