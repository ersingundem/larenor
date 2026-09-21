import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/resource_reservations/data/resource_reservation_api.dart';
import 'package:larenor/features/resource_reservations/domain/resource_reservation_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _AuthApi extends LarenorServerApi {
  _AuthApi(this.value)
    : super(
        endpoint: value.endpoint,
        client: MockClient((_) async => http.Response('{}', 500)),
      );
  final ServerSession value;
  @override
  Future<ServerUser> me(String token) async => value.user;
  @override
  Future<ServerContext> context(String token) async => value.context!;
}

http.Response _json(Object? value, [int status = 200]) => http.Response(
  value == null ? '' : jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  const core = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
  const home = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
  const accountId = 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0';
  const sessionId = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
  const resource = 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0';
  const command = 'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
  });
  final endpoint = ServerEndpoint('https://synthetic.invalid/prefix');
  final user = ServerUser(
    id: accountId,
    username: 'Fixture',
    role: ServerRole.admin,
    mustChangePassword: false,
  );
  final session = ServerSession(
    endpoint: endpoint,
    accessToken: 'synthetic_access_1234567890',
    refreshToken: 'synthetic_refresh_1234567890',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
    user: user,
    context: context,
  );
  final authority = {
    'coreId': core,
    'homeId': home,
    'accountId': accountId,
    'sessionId': sessionId,
    'coreRevision': 1,
    'homeRevision': 1,
    'accountRevision': 2,
    'membersRevision': 2,
    'resourceId': resource,
    'resourceRevision': 1,
  };
  final resourceValue = {
    'id': resource,
    'revision': 1,
    'label': 'Shared home resource',
    'timezone': 'UTC',
    'capacity': 1,
  };

  test(
    'authenticated transport binds exact route and never retries writes',
    () async {
      final store = _Store(session);
      final account = ServerAccountController(
        store: store,
        apiFactory: (_) => _AuthApi(session),
      );
      addTearDown(account.dispose);
      await account.initialize();
      var calls = 0;
      late Map<String, dynamic> createBody;
      final client = MockClient((request) async {
        calls++;
        expect(
          request.headers['authorization'],
          'Bearer ${session.accessToken}',
        );
        final suffix = request.url.path.replaceFirst('/prefix/api/v1', '');
        if (suffix.endsWith('/authority')) {
          expect(request.method, 'GET');
          return _json({
            'schemaVersion': 1,
            'authority': authority,
            'calendarRevision': 1,
            'resource': resourceValue,
          });
        }
        if (suffix.endsWith('/snapshot')) {
          return _json({
            'schemaVersion': 1,
            'authority': authority,
            'calendarRevision': 1,
            'resource': resourceValue,
            'canCreate': true,
            'reservations': [],
            'history': [],
            'busy': [],
          });
        }
        createBody = jsonDecode(request.body) as Map<String, dynamic>;
        expect(suffix, endsWith('/commands/create'));
        return _json({
          'schemaVersion': 1,
          'authority': authority,
          'eventId': 'event-create',
          'actorId': accountId,
          'commandId': command,
          'action': 'create',
          'expectedCalendarRevision': 1,
          'calendarRevision': 2,
          'reservation': {
            'id': 'reservation-1',
            'ownerId': accountId,
            'resourceId': resource,
            'timezone': 'UTC',
            'localStart': '2026-11-01T10:00:00',
            'fold': 0,
            'durationSeconds': 3600,
            'units': 1,
            'recurrence': {'frequency': 'none', 'count': 1},
            'occurrences': [
              {
                'startUtc': '2026-11-01T10:00:00Z',
                'endUtc': '2026-11-01T11:00:00Z',
              },
            ],
            'canCancel': true,
            'cancelled': false,
          },
        });
      });
      var current = true;
      final api = await ResourceReservationAccountApi.connect(
        account: account,
        context: context,
        routeId: 'route-reservations',
        isCurrent: () => current,
        apiFactory: (value) =>
            LarenorServerApi(endpoint: value, client: client),
      );
      addTearDown(api.close);
      final snapshot = await api.snapshot(api.authority);
      expect(snapshot.calendarRevision, 1);
      final draft = ReservationDraft.tryCreate(
        timezone: 'UTC',
        localStart: '2026-11-01T10:00:00',
        fold: 0,
        durationMinutes: 60,
        units: 1,
        frequency: 'none',
        recurrenceCount: 1,
        capacity: 1,
      )!;
      final receipt = await api.create(
        api.authority,
        expectedCalendarRevision: 1,
        commandId: command,
        draft: draft,
      );
      expect(receipt.calendarRevision, 2);
      expect(createBody['sessionId'], sessionId);
      expect(createBody['expectedCalendarRevision'], 1);
      expect(calls, 3);

      current = false;
      await expectLater(
        api.export(api.authority, expectedCalendarRevision: 2, limit: 256),
        throwsA(
          isA<ReservationApiException>().having(
            (error) => error.code,
            'code',
            'authority_changed',
          ),
        ),
      );
      expect(calls, 3);
    },
  );
}
