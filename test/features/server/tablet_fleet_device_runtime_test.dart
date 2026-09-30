import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_credential_store.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_profile_store.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_runtime_scope.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/tablet_fleet/domain/server_tablet_fleet_models.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/tablet_fleet_device_runtime.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/tablet_fleet_device_store.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/tablet_fleet_device_runtime_scope.dart';
import 'package:larenor/features/server/tablet_fleet/presentation/tablet_fleet_this_device_card.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _account = '33333333333333333333333333333333';
const _registration = '44444444444444444444444444444444';

TabletFleetDeviceBinding get _binding => TabletFleetDeviceBinding(
  serverBaseUrl: 'https://core.example',
  coreId: _core,
  homeId: _home,
  accountId: _account,
  sessionFamilyId: '55555555555555555555555555555555',
);

ManagedTablet _tablet({
  int revision = 1,
  int desired = 1,
  int applied = 1,
  TabletManagementMode mode = TabletManagementMode.standard,
  TabletFleetState state = TabletFleetState.active,
}) => ManagedTablet.fromJson({
  'schemaVersion': 1,
  'ref': {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'kind': 'managed_tablet',
    'id': _registration,
  },
  'revision': revision,
  'name': 'Kitchen tablet',
  'platform': 'android',
  'managementMode': mode.name,
  'capabilities': mode == TabletManagementMode.deviceOwner
      ? ['notifications', 'kiosk', 'media', 'screen', 'kioskLock']
      : ['notifications', 'kiosk', 'media', 'screen'],
  'clientVersion': '1.0.0+1',
  'desiredProfileRevision': desired,
  'appliedProfileRevision': applied,
  'state': state.name,
  'profileState': desired == applied ? 'current' : 'updateRequired',
  'lastSeenAt': 1000.0,
});

ManagedTabletCommand _command({
  String id = '66666666666666666666666666666666',
  int sequence = 1,
  TabletCommandKind kind = TabletCommandKind.refreshDashboard,
  TabletCommandState state = TabletCommandState.delivered,
  TabletCommandResult? result,
}) => ManagedTabletCommand.fromJson({
  'schemaVersion': 1,
  'id': id,
  'sequence': sequence,
  'command': kind.name,
  'requiredMode': kind.requiredMode.name,
  'policyRevision': 1,
  'expiresAt': 2000.0,
  'state': state.name,
  'result': result?.name,
  'createdAt': 1000.0,
  'completedAt': state == TabletCommandState.completed ? 1500.0 : null,
});

ManagedTabletProfilePublication _publication({
  int deviceRevision = 1,
  int revision = 2,
}) => ManagedTabletProfilePublication.fromJson({
  'publication': {
    'schemaVersion': 1,
    'deviceId': _registration,
    'deviceRevision': deviceRevision,
    'revision': revision,
    'digest': 'a' * 64,
    'document': {
      'schemaVersion': 1,
      'fullscreen': true,
      'idleTimeoutSeconds': 300,
    },
    'updatedAt': 1200.0,
  },
});

final class _MemoryStore implements TabletFleetDeviceStore {
  TabletFleetDeviceRecord? value;
  final writes = <TabletFleetDeviceRecord?>[];

  @override
  Future<TabletFleetDeviceRecord?> read() async => value;

  @override
  Future<void> write(TabletFleetDeviceRecord? next) async {
    value = next;
    writes.add(next);
  }
}

final class _SessionStore implements ServerSessionPersistence {
  _SessionStore(this.value);
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? value) async => this.value = value;
}

final class _CredentialStore implements ManagedTabletCredentialStore {
  _CredentialStore(this.value);
  ManagedTabletEnrollment? value;

  @override
  Future<ManagedTabletEnrollment?> read() async => value;

  @override
  Future<void> write(ManagedTabletEnrollment value) async => this.value = value;

  @override
  Future<void> clearIfCurrent(
    ManagedTabletBinding binding,
    String pairingId,
  ) async {
    if (value?.binding == binding && value?.pairingId == pairingId) {
      value = null;
    }
  }

  @override
  Future<void> clearIfExact(ManagedTabletEnrollment enrollment) async {
    if (value?.binding == enrollment.binding &&
        value?.pairingId == enrollment.pairingId &&
        value?.revision == enrollment.revision) {
      value = null;
    }
  }
}

final class _ProfilePersistence implements ManagedTabletProfilePersistence {
  String? value, confirmation;

  @override
  Future<String?> read() async => value;

  @override
  Future<String?> readConfirmation() async => confirmation;

  @override
  Future<void> write(String? value) async => this.value = value;

  @override
  Future<void> writeConfirmation(String? value) async => confirmation = value;
}

final class _Client implements TabletFleetDeviceClient {
  ManagedTablet tablet = _tablet();
  final commands = <ManagedTabletCommand>[];
  final completions = <TabletCommandResult>[];
  int registrations = 0, heartbeats = 0, polls = 0, revocations = 0;
  bool failCompletion = false;
  ManagedTabletProfilePublication? publication;
  Completer<void>? heartbeatGate;

  @override
  Future<ManagedTablet> register({
    required String registrationId,
    required String name,
    required String clientVersion,
    required TabletManagementMode mode,
    required int appliedProfileRevision,
  }) async {
    registrations++;
    tablet = _tablet(mode: mode);
    return tablet;
  }

  @override
  Future<ManagedTablet> heartbeat(
    ManagedTablet current, {
    required String clientVersion,
    required int appliedProfileRevision,
  }) async {
    heartbeats++;
    await heartbeatGate?.future;
    return tablet;
  }

  @override
  Future<ManagedTablet> refresh(ManagedTablet current) async => tablet;

  @override
  Future<ManagedTabletCommandPage> poll(
    ManagedTablet current, {
    required int after,
  }) async => ManagedTabletCommandPage.fromJson({
    'schemaVersion': 1,
    'tabletRevision': current.revision,
    'commands': [
      for (final command
          in (polls++ == 0) ? commands : const <ManagedTabletCommand>[])
        command.toJson(),
    ],
    'nextAfter': null,
  });

  @override
  Future<ManagedTabletProfilePublication> readProfile(
    ManagedTablet current,
  ) async => publication ?? (throw StateError('missing publication'));

  @override
  Future<ManagedTablet> acknowledgeProfile(
    ManagedTablet current,
    ManagedTabletProfilePublication publication, {
    required String clientVersion,
  }) async {
    tablet = _tablet(
      revision: current.revision,
      desired: publication.revision,
      applied: publication.revision,
      mode: current.mode,
    );
    return tablet;
  }

  @override
  Future<ManagedTabletCommand> complete(
    ManagedTablet current,
    ManagedTabletCommand command,
    TabletCommandResult result, {
    required int appliedProfileRevision,
  }) async {
    completions.add(result);
    if (failCompletion) {
      throw const LarenorServerException('connection_failed');
    }
    return _command(
      id: command.id,
      sequence: command.sequence,
      kind: command.kind,
      state: TabletCommandState.completed,
      result: result,
    );
  }

  @override
  Future<void> revoke(ManagedTablet current) async {
    revocations++;
  }
}

final class _Authority implements TabletFleetDeviceAuthority {
  _Authority(this.client);
  final _Client client;
  TabletFleetDeviceBinding? binding = _binding;

  @override
  TabletFleetDeviceBinding? currentBinding() => binding;

  @override
  Future<T> withClient<T>(
    TabletFleetDeviceBinding expected,
    Future<T> Function(TabletFleetDeviceClient client) action,
  ) async {
    if (binding != expected) {
      throw const LarenorServerException('retired');
    }
    final result = await action(client);
    if (binding != expected) {
      throw const LarenorServerException('retired');
    }
    return result;
  }
}

final class _Platform implements TabletFleetDevicePlatform {
  TabletManagementMode mode = TabletManagementMode.standard;
  int effects = 0;
  TabletCommandResult result = TabletCommandResult.succeeded;
  int profiles = 0;
  int restores = 0, clears = 0;

  @override
  Future<TabletManagementMode> managementMode() async => mode;

  @override
  Future<TabletCommandResult> execute(
    TabletCommandKind command, {
    required bool Function() current,
  }) async {
    expect(current(), isTrue);
    effects++;
    return result;
  }

  @override
  Future<TabletCommandResult> applyProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required ManagedTabletProfilePublication publication,
    required bool Function() current,
  }) async {
    if (!current()) return TabletCommandResult.denied;
    profiles++;
    return result;
  }

  @override
  Future<void> restoreProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required bool Function() current,
  }) async {
    expect(current(), isTrue);
    restores++;
  }

  @override
  Future<void> retireProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
  }) async => clears++;
}

final class _ComposedProfilePlatform implements TabletFleetDevicePlatform {
  const _ComposedProfilePlatform({
    required this.authority,
    required this.profile,
    required this.activation,
  });

  final ManagedTabletProfileAuthority authority;
  final AppliedManagedTabletProfile profile;
  final ManagedTabletProfileActivation activation;

  @override
  Future<TabletManagementMode> managementMode() async =>
      TabletManagementMode.standard;

  @override
  Future<TabletCommandResult> execute(
    TabletCommandKind command, {
    required bool Function() current,
  }) async => TabletCommandResult.unsupported;

  @override
  Future<TabletCommandResult> applyProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required ManagedTabletProfilePublication publication,
    required bool Function() current,
  }) async => TabletCommandResult.unsupported;

  @override
  Future<void> restoreProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required bool Function() current,
  }) async {
    if (!current()) throw StateError('retired');
    await activation.activate(authority, profile);
  }

  @override
  Future<void> retireProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
  }) => activation.activate(authority, null);
}

ManagedTabletProfilePublication _verifiedPublication() {
  final digest = sha256
      .convert(
        utf8.encode(jsonEncode([1, _core, _home, _registration, true, 300])),
      )
      .toString();
  return ManagedTabletProfilePublication.fromJson({
    'publication': {
      'schemaVersion': 1,
      'deviceId': _registration,
      'deviceRevision': 2,
      'revision': 2,
      'digest': digest,
      'document': {
        'schemaVersion': 1,
        'fullscreen': true,
        'idleTimeoutSeconds': 300,
      },
      'updatedAt': 1200.0,
    },
  });
}

TabletFleetDeviceRuntime _runtime({
  required _MemoryStore store,
  required _Authority authority,
  required TabletFleetDevicePlatform platform,
}) => TabletFleetDeviceRuntime(
  authority: authority,
  store: store,
  platform: platform,
  registrationId: () => _registration,
  clientVersion: () async => '1.0.0+1',
);

void main() {
  test(
    'explicit enrollment persists exact account/home scope and resumes',
    () async {
      final client = _Client();
      final store = _MemoryStore();
      final authority = _Authority(client);
      final platform = _Platform();
      final first = _runtime(
        store: store,
        authority: authority,
        platform: platform,
      );

      await first.initialize();
      expect(client.registrations, 0);
      expect(platform.clears, 0);
      await first.enroll('Kitchen tablet');
      expect(client.registrations, 1);
      expect(store.value?.binding, _binding);

      final restarted = _runtime(
        store: store,
        authority: authority,
        platform: platform,
      );
      await restarted.initialize();
      await restarted.synchronize();
      expect(client.registrations, 1);
      expect(client.heartbeats, 1);
    },
  );

  test('account or home drift retires local enrollment without I/O', () async {
    final client = _Client();
    final store = _MemoryStore()
      ..value = TabletFleetDeviceRecord.enrolled(
        binding: _binding,
        tablet: _tablet(),
      );
    final authority = _Authority(client)
      ..binding = TabletFleetDeviceBinding(
        serverBaseUrl: 'https://core.example',
        coreId: _core,
        homeId: '77777777777777777777777777777777',
        accountId: _account,
        sessionFamilyId: '55555555555555555555555555555555',
      );
    final runtime = _runtime(
      store: store,
      authority: authority,
      platform: _Platform(),
    );

    await runtime.initialize();
    expect(store.value, isNull);
    expect(runtime.record, isNull);
    expect(client.heartbeats, 0);
    expect(client.polls, 0);
  });

  test(
    'authority initialize queued during I/O retires the old enrollment',
    () async {
      final client = _Client()..heartbeatGate = Completer<void>();
      final store = _MemoryStore()
        ..value = TabletFleetDeviceRecord.enrolled(
          binding: _binding,
          tablet: _tablet(),
        );
      final authority = _Authority(client);
      final runtime = _runtime(
        store: store,
        authority: authority,
        platform: _Platform(),
      );
      await runtime.initialize();

      final sync = runtime.synchronize();
      while (client.heartbeats == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      authority.binding = null;
      final reconcile = runtime.initialize();
      client.heartbeatGate!.complete();
      await sync;
      await reconcile;

      expect(runtime.enrolled, isFalse);
      expect(runtime.status, TabletFleetDeviceRuntimeStatus.retired);
      expect(store.value, isNull);
    },
  );

  test(
    'effect is reserved before I/O and lost completion ack never replays it',
    () async {
      final client = _Client()
        ..commands.add(_command())
        ..failCompletion = true;
      final store = _MemoryStore()
        ..value = TabletFleetDeviceRecord.enrolled(
          binding: _binding,
          tablet: _tablet(),
        );
      final authority = _Authority(client);
      final platform = _Platform();
      final runtime = _runtime(
        store: store,
        authority: authority,
        platform: platform,
      );

      await runtime.initialize();
      await runtime.synchronize();
      expect(platform.effects, 1);
      expect(
        store.writes.any((value) => value?.pending?.result == null),
        isTrue,
      );
      expect(store.value?.pending?.result, TabletCommandResult.succeeded);

      client.failCompletion = false;
      final restarted = _runtime(
        store: store,
        authority: authority,
        platform: platform,
      );
      await restarted.initialize();
      await restarted.synchronize();
      expect(platform.effects, 1);
      expect(client.completions, [
        TabletCommandResult.succeeded,
        TabletCommandResult.succeeded,
      ]);
      expect(store.value?.pending, isNull);
      expect(store.value?.after, 1);
    },
  );

  test(
    'crash after reservation completes failed and never repeats unknown effect',
    () async {
      final store = _MemoryStore()
        ..value = TabletFleetDeviceRecord.enrolled(
          binding: _binding,
          tablet: _tablet(),
        ).withPending(_command());
      final client = _Client();
      final platform = _Platform();
      final runtime = _runtime(
        store: store,
        authority: _Authority(client),
        platform: platform,
      );

      await runtime.initialize();
      await runtime.synchronize();
      expect(platform.effects, 0);
      expect(client.completions, [TabletCommandResult.failed]);
      expect(store.value?.after, 1);
    },
  );

  test(
    'syncProfile applies exact publication before acknowledging revision',
    () async {
      final client = _Client()
        ..tablet = _tablet(desired: 2)
        ..publication = _publication()
        ..commands.add(_command(kind: TabletCommandKind.syncProfile));
      final store = _MemoryStore()
        ..value = TabletFleetDeviceRecord.enrolled(
          binding: _binding,
          tablet: _tablet(desired: 2),
        );
      final platform = _Platform();
      final runtime = _runtime(
        store: store,
        authority: _Authority(client),
        platform: platform,
      );

      await runtime.initialize();
      await runtime.synchronize();

      expect(platform.profiles, 1);
      expect(store.value?.tablet.appliedProfileRevision, 2);
      expect(store.value?.tablet.profileState, TabletProfileState.current);
      expect(client.completions, [TabletCommandResult.succeeded]);
    },
  );

  test('revoke stops polling and removes the persisted enrollment', () async {
    final client = _Client();
    final store = _MemoryStore()
      ..value = TabletFleetDeviceRecord.enrolled(
        binding: _binding,
        tablet: _tablet(),
      );
    final runtime = _runtime(
      store: store,
      authority: _Authority(client),
      platform: _Platform(),
    );
    await runtime.initialize();

    await runtime.revoke();
    await runtime.synchronize();
    expect(client.revocations, 1);
    expect(client.polls, 0);
    expect(store.value, isNull);
  });

  testWidgets(
    'composed K07 and F53 scopes isolate profile retirement and logout',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.utc(2026, 9, 30, 12);
      final sessionStore = _SessionStore(
        ServerSession(
          endpoint: ServerEndpoint('https://core.example'),
          accessToken: 'synthetic_access_token_12345',
          refreshToken: 'synthetic_refresh_token_12345',
          expiresAt: now.add(const Duration(hours: 1)),
          user: const ServerUser(
            id: _account,
            username: 'admin',
            role: ServerRole.admin,
            mustChangePassword: false,
          ),
          sessionFamilyId: '55555555555555555555555555555555',
          context: ServerContext.fromJson({
            'schemaVersion': 1,
            'coreId': _core,
            'homeId': _home,
          }),
        ),
      );
      final account = ServerAccountController(
        store: sessionStore,
        clock: () => now,
        apiFactory: (endpoint) => LarenorServerApi(
          endpoint: endpoint,
          clock: () => now,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/auth/me')) {
              return http.Response(
                jsonEncode({
                  'user': {
                    'id': _account,
                    'username': 'admin',
                    'role': 'admin',
                    'mustChangePassword': false,
                  },
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path.endsWith('/auth/logout')) {
              return http.Response('', 204);
            }
            if (request.url.path.endsWith('/context')) {
              return http.Response(
                jsonEncode({
                  'schemaVersion': 1,
                  'coreId': _core,
                  'homeId': _home,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            throw StateError('unexpected ${request.method} ${request.url}');
          }),
        ),
      );
      addTearDown(account.dispose);
      await account.initialize();
      expect(account.session?.context, isNotNull);

      final profileStore = ManagedTabletProfileStore(_ProfilePersistence());
      final fleetProfileAuthority = ManagedTabletProfileAuthority(
        serverBaseUrl: _binding.serverBaseUrl,
        coreId: _binding.coreId,
        homeId: _binding.homeId,
        accountId: _binding.accountId,
        deviceId: _registration,
        sourceId: 'fleet:${_binding.sessionFamilyId}',
      );
      final fleetProfile = await profileStore.applyForAuthority(
        fleetProfileAuthority,
        _verifiedPublication(),
        expectedDeviceId: _registration,
        isCurrent: () => true,
      );
      final k07PairingId = '77777777777777777777777777777777';
      final credentials = _CredentialStore(
        ManagedTabletEnrollment(
          serverBaseUrl: _binding.serverBaseUrl,
          coreId: _binding.coreId,
          homeId: _binding.homeId,
          accountId: _binding.accountId,
          pairingId: k07PairingId,
          deviceId: '88888888888888888888888888888888',
          revision: 1,
          scopes: const {'read', 'control'},
          expiresAt: DateTime.utc(2030),
          token: 'A' * 43,
          clientId: 'larenor-$k07PairingId',
          topicPrefix: 'larenor/$k07PairingId',
        ),
      );
      final fleetStore = _MemoryStore()
        ..value = TabletFleetDeviceRecord.enrolled(
          binding: _binding,
          tablet: _tablet(revision: 2, desired: 2, applied: 2),
        );
      final fleetAuthority = _Authority(_Client());
      late TabletFleetDeviceRuntime fleetRuntime;
      final container = ProviderContainer(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(account),
          managedTabletCredentialStoreProvider.overrideWithValue(credentials),
          managedTabletProfileStoreProvider.overrideWithValue(profileStore),
          tabletFleetDeviceRuntimeProvider.overrideWith((ref) {
            fleetRuntime = _runtime(
              store: fleetStore,
              authority: fleetAuthority,
              platform: _ComposedProfilePlatform(
                authority: fleetProfileAuthority,
                profile: fleetProfile,
                activation: ref.read(managedTabletProfileActivationProvider),
              ),
            );
            return fleetRuntime;
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ManagedTabletRuntimeScope(
            child: TabletFleetDeviceRuntimeScope(child: SizedBox()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        container.read(managedTabletActiveProfileProvider),
        same(fleetProfile),
      );
      expect(
        await container.read(windowProfileProvider.future),
        WindowProfile.panel,
      );
      expect(
        (await container.read(idleModeProvider.future)).timeoutSeconds,
        300,
      );

      // K07 has no matching durable profile. Its exact retirement callback is
      // stale relative to the active F53 source and cannot clear that source.
      await container
          .read(managedTabletRuntimeOwnerProvider)
          .revoke(k07PairingId);
      expect(credentials.value, isNull);
      expect(
        container.read(managedTabletActiveProfileProvider),
        same(fleetProfile),
      );

      // A real account logout retires the F53 binding as well, so both source
      // scopes converge on local, unmanaged settings.
      fleetAuthority.binding = null;
      await account.signOut();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(container.read(managedTabletActiveProfileProvider), isNull);
      expect(
        await container.read(windowProfileProvider.future),
        WindowProfile.adaptive,
      );
      expect((await container.read(idleModeProvider.future)).enabled, isFalse);
    },
  );

  testWidgets('explicit this-device control enrolls only after user action', (
    tester,
  ) async {
    final client = _Client();
    final store = _MemoryStore();
    final runtime = _runtime(
      store: store,
      authority: _Authority(client),
      platform: _Platform(),
    );
    await runtime.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tabletFleetDeviceRuntimeProvider.overrideWith((ref) => runtime),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: TabletFleetThisDeviceCard(
              enabled: true,
              current: _alwaysCurrent,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('tablet-fleet-this-device-name')),
      'Kitchen tablet',
    );
    expect(client.registrations, 0);
    await tester.tap(
      find.byKey(const ValueKey('tablet-fleet-enroll-this-device')),
    );
    await tester.pumpAndSettle();
    expect(client.registrations, 1);
    expect(
      find.byKey(const ValueKey('tablet-fleet-this-device-status')),
      findsOneWidget,
    );
  });
}

bool _alwaysCurrent() => true;
