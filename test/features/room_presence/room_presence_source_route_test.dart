import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/room_presence/data/room_presence_source_api.dart';
import 'package:larenor/features/room_presence/domain/room_presence_source_models.dart';
import 'package:larenor/features/room_presence/presentation/room_presence_management_screen.dart';
import 'package:larenor/features/room_presence/presentation/room_presence_route.dart';
import 'package:larenor/features/room_presence/presentation/room_presence_source_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

final class _Source implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;

  @override
  Future<void> write(HomeSource source) async {}
}

final class _SetupApi implements RoomPresenceSourceApi {
  _SetupApi(this.current, {this.configuration});
  final bool Function() current;
  RoomPresenceSourceConfiguration? configuration;
  bool retired = false;
  int entityCalls = 0, saveCalls = 0, revokeCalls = 0;
  Map<String, Object?>? saved;

  static final service = ServerService.fromJson({
    'id': '1' * 32,
    'name': 'Verified Home Assistant',
    'kind': 'home_assistant',
    'baseUrl': 'https://ha.fixture.invalid',
    'revision': 3,
    'credentialKeys': ['token'],
    'verification': {
      'state': 'authenticated',
      'checkedAt': '2026-09-05T08:00:00Z',
      'version': '2026.9',
    },
  });
  static final room = HomeResourceRecord.fromJson(
    {
      'ref': {
        'schemaVersion': 1,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
        'kind': 'room',
        'id': '2' * 32,
      },
      'label': 'Living room',
      'order': 0,
      'revision': 4,
      'aclRevision': 1,
      'permissions': {'read': true, 'write': true},
    },
    expectedContext: ServerContext.fromJson({
      'schemaVersion': 1,
      'coreId': 'a' * 32,
      'homeId': 'b' * 32,
    }),
  );

  void _guard() {
    if (retired || !current()) throw StateError('stale setup');
  }

  @override
  Future<RoomPresenceSetupCatalog> load() async {
    _guard();
    return RoomPresenceSetupCatalog(
      services: [service],
      rooms: [room],
      configuration: configuration,
    );
  }

  @override
  Future<List<RoomPresenceEntityCandidate>> entities(
    ServerService selected,
  ) async {
    _guard();
    expect(selected, same(service));
    entityCalls++;
    return const [
      RoomPresenceEntityCandidate(
        candidateId:
            '3333333333333333333333333333333333333333333333333333333333333333',
        entityId: 'sensor.owner_room',
        name: 'Owner room',
      ),
    ];
  }

  @override
  Future<RoomPresenceSourceConfiguration> save(
    Map<String, Object?> body,
  ) async {
    _guard();
    saveCalls++;
    saved = Map.unmodifiable(body);
    return configuration = RoomPresenceSourceConfiguration(
      revision: 1,
      serviceId: service.id,
      serviceRevision: service.revision,
      entityId: 'sensor.owner_room',
      entityName: 'Owner room',
      consentActive: true,
      maxSignalAgeMs: 30000,
      rooms: const [
        RoomPresenceConfiguredRoom(
          roomId: '22222222222222222222222222222222',
          roomRevision: 4,
          roomLabel: 'Living room',
        ),
      ],
    );
  }

  @override
  Future<RoomPresenceSourceConfiguration> revoke(int expectedRevision) async {
    _guard();
    revokeCalls++;
    expect(expectedRevision, 1);
    return configuration = RoomPresenceSourceConfiguration(
      revision: 2,
      serviceId: service.id,
      serviceRevision: service.revision,
      entityId: 'sensor.owner_room',
      entityName: 'Owner room',
      consentActive: false,
      maxSignalAgeMs: 30000,
      rooms: const [
        RoomPresenceConfiguredRoom(
          roomId: '22222222222222222222222222222222',
          roomRevision: 4,
          roomLabel: 'Living room',
        ),
      ],
    );
  }

  @override
  void retire() => retired = true;
}

Map<String, Object?> _authority(Map<String, dynamic> request) => {
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'accountId': adminId,
  'sessionFamilyId': sessionFamilyId,
  'routeId': request['routeId'],
  'homeRevision': 1,
  'accountRevision': 1,
  'clientSessionRevision': request['clientSessionRevision'],
  'routeRevision': request['routeRevision'],
  'bindingTag': 'f' * 64,
};

void main() {
  testWidgets('inline setup keeps parent authority through picker and save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = AdminFixture();
    await fixture.account.initialize();
    final home = HomeSessionController(
      store: _Source(),
      account: fixture.account,
    );
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
    addTearDown(() {
      home.dispose();
      fixture.account.dispose();
    });
    late _SetupApi setup;
    final client = MockClient((request) async {
      final body = request.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path.endsWith('/scope')) {
        return http.Response(
          jsonEncode(_authority(body)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.endsWith('/devices/query')) {
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'authority': body['authority'],
            'devices': <Object?>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'error': {'code': 'not_found'},
        }),
        404,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeSessionControllerProvider.overrideWithValue(home),
          windowPolicySnapshotProvider.overrideWith((_) async* {
            yield const WindowPolicySnapshot(
              supported: false,
              isResumed: true,
              hasWindowFocus: true,
              reason: WindowRestrictionReason.unsupported,
            );
          }),
        ],
        child: AppInteractionScope(
          controller: home.interaction,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RoomPresenceRoute(
              apiFactory: (endpoint) =>
                  LarenorServerApi(endpoint: endpoint, client: client),
              sourceApiFactory: (_, current) => setup = _SetupApi(current),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomPresenceManagementScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('presence-configure-source')));
    await tester.pumpAndSettle();
    expect(find.byType(RoomPresenceSourceScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('presence-setup-service')));
    await tester.pumpAndSettle();
    expect(setup.current(), isTrue);
    await tester.tap(find.text('Verified Home Assistant').last);
    await tester.pumpAndSettle();
    expect(setup.entityCalls, 1);

    await tester.tap(find.byKey(const ValueKey('presence-setup-entity')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Owner room').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('presence-setup-room')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Living room').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('presence-setup-max-age')),
        matching: find.byType(CupertinoTextField),
      ),
      '30000',
    );
    await tester.tap(find.byKey(const ValueKey('presence-setup-consent')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('presence-setup-save')),
    );
    await tester.tap(find.byKey(const ValueKey('presence-setup-save')));
    await tester.pumpAndSettle();

    expect(setup.saveCalls, 1);
    expect(setup.saved?['candidateId'], '3' * 64);
    expect(setup.saved?['consent'], true);
    expect(setup.retired, isTrue);
    expect(find.byType(RoomPresenceManagementScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('active consent can be revoked then discovery re-enabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _SetupApi(
      () => true,
      configuration: RoomPresenceSourceConfiguration(
        revision: 1,
        serviceId: _SetupApi.service.id,
        serviceRevision: _SetupApi.service.revision,
        entityId: 'sensor.owner_room',
        entityName: 'Owner room',
        consentActive: true,
        maxSignalAgeMs: 30000,
        rooms: const [
          RoomPresenceConfiguredRoom(
            roomId: '22222222222222222222222222222222',
            roomRevision: 4,
            roomLabel: 'Living room',
          ),
        ],
      ),
    );
    var finished = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: RoomPresenceSourceScreen(
          api: api,
          strings: RoomPresenceSetupStrings.en,
          onFinished: () async => finished++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.entityCalls, 1);

    await tester.tap(find.byKey(const ValueKey('presence-setup-revoke')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke consent').last);
    await tester.pumpAndSettle();
    expect(api.revokeCalls, 1);
    expect(find.textContaining('Consent is revoked'), findsOneWidget);
    expect(find.byKey(const ValueKey('presence-setup-revoke')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('presence-setup-service')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verified Home Assistant').last);
    await tester.pumpAndSettle();
    expect(api.entityCalls, 2);
    await tester.tap(find.byKey(const ValueKey('presence-setup-entity')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Owner room').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('presence-setup-consent')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('presence-setup-save')),
    );
    await tester.tap(find.byKey(const ValueKey('presence-setup-save')));
    await tester.pumpAndSettle();
    expect(api.saveCalls, 1);
    expect(api.saved?['expectedRevision'], 2);
    expect(api.saved?['consent'], true);
    expect(finished, 1);
    expect(tester.takeException(), isNull);
  });
}
