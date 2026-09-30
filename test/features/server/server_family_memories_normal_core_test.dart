import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/family_memories/data/server_family_memories_api.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_MEMORY_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client → normal Core → Immich preserves multi-album provenance',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Memory source gate',
      );
      expect(account.failure, isNull);
      await account.withSession((transport, session) async {
        final api = ServerFamilyMemoriesApi(transport, session.accessToken);
        final initial = await api.sources();
        final service = initial.services.single;
        final albums = await api.sourceAlbums(service);
        expect(albums.map((value) => value.title), ['Trip', 'Archive']);
        final granted = await api.grantSource(
          initial,
          service,
          albums.map((value) => value.albumId).toList(),
        );
        expect(granted.binding?.allowedAlbumIds, [
          '11111111-1111-4111-8111-111111111111',
          '22222222-2222-4222-8222-222222222222',
        ]);
        final snapshot = await api.snapshot();
        final results = await api.search(
          authority: snapshot.authority,
          serviceId: service.serviceId,
          serviceRevision: service.serviceRevision,
          query: 'family trip',
          albumIds: granted.binding!.allowedAlbumIds,
          limit: 3,
        );
        expect(results.map((value) => value.assetId).toList(), [
          '44444444-4444-4444-8444-444444444444',
          '55555555-5555-4555-8555-555555555555',
        ]);
        expect(results.map((value) => value.sourceAlbumId).toList(), [
          '11111111-1111-4111-8111-111111111111',
          '22222222-2222-4222-8222-222222222222',
        ]);
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
