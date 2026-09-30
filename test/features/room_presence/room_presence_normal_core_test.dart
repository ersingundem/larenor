import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_presence/data/room_presence_management_api.dart';
import 'package:larenor/features/room_presence/data/room_presence_source_api.dart';
import 'package:larenor/features/room_presence/domain/room_presence_management_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_PRESENCE_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'actual Client configures MQTT-room evidence and revokes it offline',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Presence acceptance',
      );
      expect(account.failure, isNull);
      final session = account.session!;
      final source = AccountRoomPresenceSourceApi(
        account: account,
        isCurrent: () => true,
      );
      addTearDown(source.retire);

      final setup = await source.load();
      expect(setup.configuration, isNull);
      final service = setup.services.single;
      final room = setup.rooms.single;
      final entity = (await source.entities(service)).single;
      final active = await source.save({
        'schemaVersion': 1,
        'expectedRevision': null,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'entityId': entity.entityId,
        'candidateId': entity.candidateId,
        'roomId': room.id,
        'expectedRoomRevision': room.revision,
        'maxSignalAgeMs': 30000,
        'consent': true,
      });
      expect(active.revision, 1);
      expect(active.consentActive, isTrue);

      final gateway = RoomPresenceAccountGateway(
        account: account,
        context: session.context!,
        routeId: '57575757575757575757575757575757',
        routeRevision: 1,
        isCurrent: () => true,
      );
      addTearDown(gateway.close);
      final authority = await gateway.bootstrap();
      final first = (await gateway.list(authority)).single;
      expect(first.state, PresenceEvidenceState.candidate);
      expect(first.grantsAccess, isFalse);
      final second = (await gateway.list(authority)).single;
      expect(second.state, PresenceEvidenceState.present);
      expect(second.sourceKinds, ['ha_mqtt_room']);
      expect(second.grantsAccess, isFalse);

      final revoked = await source.revoke(active.revision);
      expect(revoked.revision, 2);
      expect(revoked.consentActive, isFalse);
      expect(await gateway.list(authority), isEmpty);

      await expectLater(
        source.save({
          'schemaVersion': 1,
          'expectedRevision': active.revision,
          'serviceId': service.id,
          'expectedServiceRevision': service.revision,
          'entityId': entity.entityId,
          'candidateId': entity.candidateId,
          'roomId': room.id,
          'expectedRoomRevision': room.revision,
          'maxSignalAgeMs': 30000,
          'consent': true,
        }),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'revision_conflict',
          ),
        ),
      );
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
