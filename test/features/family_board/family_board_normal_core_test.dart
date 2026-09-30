import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/family_board/data/family_board_account_gateway.dart';
import 'package:larenor/features/family_board/data/family_board_cache.dart';
import 'package:larenor/features/family_board/data/family_board_controller.dart';
import 'package:larenor/features/family_board/domain/family_board_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_home_registry.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _FileRegistryStore
    implements ServerSessionPersistence, ServerHomeRegistryPersistence {
  _FileRegistryStore(this.path);
  final File path;

  @override
  Future<ServerHomeRegistry> readRegistry() async => path.existsSync()
      ? ServerHomeRegistry.decode(await path.readAsString())
      : const ServerHomeRegistry.empty();

  @override
  Future<void> writeRegistry(ServerHomeRegistry registry) async {
    final encoded = registry.encode();
    ServerHomeRegistry.decode(encoded);
    await path.parent.create(recursive: true);
    await path.writeAsString(encoded, flush: true);
  }

  @override
  Future<ServerSession?> read() async =>
      (await readRegistry()).activeProfile?.session;

  @override
  Future<void> write(ServerSession? session) async {
    final registry = await readRegistry();
    final active = registry.activeProfile;
    if (session == null) {
      final remaining = active == null
          ? registry.profiles
          : registry.profiles
                .where((profile) => profile.profileId != active.profileId)
                .toList(growable: false);
      await writeRegistry(
        ServerHomeRegistry(activeProfileId: null, profiles: remaining),
      );
      return;
    }
    if (active == null) {
      const profileId = '11111111111111111111111111111111';
      await writeRegistry(
        ServerHomeRegistry(
          activeProfileId: profileId,
          profiles: [
            ServerHomeProfile(
              profileId: profileId,
              label: 'F39 Core',
              session: session,
            ),
          ],
        ),
      );
      return;
    }
    await writeRegistry(
      ServerHomeRegistry(
        activeProfileId: active.profileId,
        profiles: [
          for (final profile in registry.profiles)
            profile.profileId == active.profileId
                ? profile.withSession(session)
                : profile,
        ],
      ),
    );
  }
}

final class _FileCacheBackend implements FamilyBoardCacheBackend {
  _FileCacheBackend(this.directory);
  final Directory directory;

  File _file(String key) => File(
    '${directory.path}/${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}',
  );

  @override
  Future<String?> read(String key) async {
    final file = _file(key);
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await directory.create(recursive: true);
    await _file(key).writeAsString(value, flush: true);
  }

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (file.existsSync()) await file.delete();
  }

  Future<String> contents() async {
    if (!directory.existsSync()) return '';
    final values = <String>[];
    await for (final entity in directory.list()) {
      if (entity is File) values.add(await entity.readAsString());
    }
    values.sort();
    return values.join('\n');
  }
}

final class _BoardClient {
  _BoardClient({
    required this.account,
    required this.binding,
    required this.gateway,
    required this.controller,
    required this.setCurrent,
  });
  final ServerAccountController account;
  final FamilyBoardBinding binding;
  final FamilyBoardAccountGateway gateway;
  final FamilyBoardController controller;
  final void Function(bool value) setCurrent;

  void close() {
    controller.dispose();
    gateway.close();
    account.dispose();
  }
}

Future<_BoardClient> _client({
  required ServerAccountController account,
  required FamilyBoardCache cache,
  required bool restore,
  required String coreUrl,
  required int routeRevision,
}) async {
  if (restore) {
    await account.initialize();
  } else {
    await account.signIn(
      baseUrl: coreUrl,
      username: 'admin',
      password: 'Synthetic new password 2026',
      deviceName: 'F39 family board $routeRevision',
    );
  }
  expect(account.failure, isNull);
  final context = account.context!;
  var current = true;
  final binding = await FamilyBoardAccountGateway.loadBinding(
    account: account,
    context: context,
    routeRevision: routeRevision,
    lifecycleRevision: 1,
    isCurrent: () => current,
  );
  final gateway = FamilyBoardAccountGateway(
    account: account,
    binding: binding,
    isCurrent: (candidate) => current && candidate == binding,
  );
  final controller = FamilyBoardController(
    gateway: gateway,
    cache: cache,
    binding: binding,
    isCurrent: (candidate) => current && candidate == binding,
  );
  return _BoardClient(
    account: account,
    binding: binding,
    gateway: gateway,
    controller: controller,
    setCurrent: (value) => current = value,
  );
}

void main() {
  final phase = Platform.environment['LARENOR_F39_PHASE'];
  final coreUrl = Platform.environment['LARENOR_F39_CORE_URL'];
  final root = Platform.environment['LARENOR_F39_CLIENT_ROOT'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client reconciles lost board command and concurrent edits across restart',
    () async {
      final registry = File('$root/session.json');
      final primaryBackend = _FileCacheBackend(
        Directory('$root/cache-primary'),
      );
      final primary = await _client(
        account: ServerAccountController(store: _FileRegistryStore(registry)),
        cache: SecureFamilyBoardCache(backend: primaryBackend),
        restore: phase == 'restart',
        coreUrl: coreUrl!,
        routeRevision: 1,
      );
      addTearDown(primary.close);
      await primary.controller.load();
      expect(primary.controller.failure, isNull);

      const privateText = 'F39 private lost-ack card';
      if (phase == 'prepare') {
        expect(primary.controller.snapshot!.boardRevision, 0);
        await primary.controller.createCard(privateText);
        expect(primary.controller.snapshot!.boardRevision, 0);
        expect(primary.controller.pendingCommand, isNotNull);
        expect(primary.controller.canMutate, isFalse);
        expect(await primaryBackend.contents(), contains(privateText));
        return;
      }

      expect(phase, 'restart');
      expect(primary.controller.pendingCommand, isNull);
      expect(primary.controller.snapshot!.boardRevision, 1);
      expect(primary.controller.snapshot!.cards.single.text, privateText);
      expect(primary.controller.canMutate, isTrue);

      final secondary = await _client(
        account: ServerAccountController(
          store: _FileRegistryStore(File('$root/secondary-session.json')),
        ),
        cache: SecureFamilyBoardCache(
          backend: _FileCacheBackend(Directory('$root/cache-secondary')),
        ),
        restore: false,
        coreUrl: coreUrl,
        routeRevision: 2,
      );
      addTearDown(secondary.close);
      await secondary.controller.load();
      expect(secondary.controller.snapshot!.boardRevision, 1);

      await primary.controller.createCard('Primary disjoint card');
      expect(primary.controller.snapshot!.boardRevision, 2);
      await secondary.controller.createCard('Secondary disjoint card');
      expect(secondary.controller.snapshot!.boardRevision, 3);
      await primary.controller.refreshDelta();
      expect(primary.controller.snapshot!.boardRevision, 3);

      final privateId = primary.controller.snapshot!.cards
          .singleWhere((card) => card.text == privateText)
          .id;
      await primary.controller.updateCard(privateId, '$privateText updated');
      expect(primary.controller.snapshot!.boardRevision, 4);
      await secondary.controller.updateCard(
        privateId,
        'Stale conflicting edit',
      );
      expect(secondary.controller.failure, BoardFailure.conflict);
      expect(secondary.controller.pendingCommand, isNull);
      expect(secondary.controller.snapshot!.boardRevision, 3);

      await primary.controller.deleteElement(privateId);
      expect(primary.controller.snapshot!.boardRevision, 5);
      expect(
        primary.controller.snapshot!.cards.map((card) => card.text),
        unorderedEquals(const [
          'Primary disjoint card',
          'Secondary disjoint card',
        ]),
      );
      expect(await primaryBackend.contents(), isNot(contains(privateText)));

      primary.setCurrent(false);
      await expectLater(
        primary.gateway.read(primary.binding),
        throwsA(
          isA<FamilyBoardException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      primary.setCurrent(true);
      await primary.account.signOut();
      await expectLater(
        primary.gateway.read(primary.binding),
        throwsA(
          isA<FamilyBoardException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
    skip: phase == null || coreUrl == null || root == null
        ? 'Requires explicit normal Core acceptance runner'
        : false,
  );
}
