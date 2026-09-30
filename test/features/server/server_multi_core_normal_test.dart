import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_home_registry.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/data/server_services_api.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

final class _FileRegistryStore
    implements ServerSessionPersistence, ServerHomeRegistryPersistence {
  _FileRegistryStore(this.path);
  final File path;
  int _nextId = 1;

  @override
  Future<ServerHomeRegistry> readRegistry() async => path.existsSync()
      ? ServerHomeRegistry.decode(await path.readAsString())
      : const ServerHomeRegistry.empty();

  @override
  Future<void> writeRegistry(ServerHomeRegistry registry) async {
    final encoded = registry.encode();
    ServerHomeRegistry.decode(encoded);
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
      final id = _nextId.toRadixString(16).padLeft(32, '0');
      _nextId++;
      await writeRegistry(
        ServerHomeRegistry(
          activeProfileId: id,
          profiles: [
            ...registry.profiles,
            ServerHomeProfile(
              profileId: id,
              label: session.endpoint.uri.host,
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

Future<List<ServerService>> _services(ServerAccountController account) =>
    account.withSession(
      (api, session) => ServerServicesApi(api, session.accessToken).list(),
    );

Future<ServerService> _register(
  ServerAccountController account, {
  required String name,
  required String baseUrl,
  required String token,
}) => account.withSession((api, session) async {
  final services = ServerServicesApi(api, session.accessToken);
  final created = await services.create(
    name: name,
    kind: ServerServiceKind.jellyfin,
    baseUrl: baseUrl,
    credentials: {'token': token},
  );
  return services.check(created);
});

void main() {
  final phase = Platform.environment['LARENOR_F19_PHASE'];
  final storePath = Platform.environment['LARENOR_F19_STORE'];
  final coreA = Platform.environment['LARENOR_F19_CORE_A'];
  final coreB = Platform.environment['LARENOR_F19_CORE_B'];
  final jellyfin = Platform.environment['LARENOR_F19_JELLYFIN'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'actual Client keeps two normal Core homes and services independent',
    () async {
      final store = _FileRegistryStore(File(storePath!));
      final account = ServerAccountController(store: store);
      addTearDown(account.dispose);
      await account.initialize();

      if (phase == 'prepare') {
        await account.signIn(
          baseUrl: coreA!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'F19 home A',
        );
        final a = await _register(
          account,
          name: 'Home A Jellyfin',
          baseUrl: jellyfin!,
          token: 'f19-home-a-private-token',
        );
        expect(
          a.verification.state,
          ServerServiceVerificationState.authenticated,
        );
        final profileA = account.activeProfileId!;
        final contextA = account.context!;

        await account.beginAddProfile();
        await account.signIn(
          baseUrl: coreB!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'F19 home B',
        );
        final b = await _register(
          account,
          name: 'Home B Jellyfin',
          baseUrl: jellyfin,
          token: 'f19-home-b-private-token',
        );
        expect(
          b.verification.state,
          ServerServiceVerificationState.authenticated,
        );
        final profileB = account.activeProfileId!;
        final contextB = account.context!;
        expect(contextB.coreId, isNot(contextA.coreId));
        expect(contextB.homeId, isNot(contextA.homeId));
        expect(account.profiles, hasLength(2));

        await account.verifyCrossHomeAuthorization(profileA);
        await account.activateProfile(profileA);
        expect((await _services(account)).single.name, 'Home A Jellyfin');
        await account.activateProfile(profileB);
        expect((await _services(account)).single.name, 'Home B Jellyfin');
      } else {
        expect(phase, 'restart');
        expect(account.profiles, hasLength(2));
        expect((await _services(account)).single.name, 'Home B Jellyfin');
        final profileB = account.activeProfileId!;
        final profileA = account.profiles
            .singleWhere((profile) => profile.profileId != profileB)
            .profileId;

        await account.activateProfile(profileA);
        expect(account.session, isNull);
        expect(account.failure, anyOf('connection_failed', 'timeout'));
        expect(account.profiles, hasLength(2));

        await account.activateProfile(profileB);
        expect(account.failure, isNull);
        expect((await _services(account)).single.name, 'Home B Jellyfin');
      }
    },
    skip:
        phase == null ||
            storePath == null ||
            coreA == null ||
            coreB == null ||
            jellyfin == null
        ? 'Requires explicit two-Core acceptance runner'
        : false,
  );
}
