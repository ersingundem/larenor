import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/features/remote_access/core/core_managed_profile_authority.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles_api.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/vnc/vnc_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

Future<CorePersonalProfilesSnapshot> _list(ServerAccountController account) =>
    account.withSession(
      (api, session) => CorePersonalProfilesApi(
        api,
        session.accessToken,
        session.context!,
        session.user.id,
        current: () => true,
      ).list(),
    );

Future<CorePersonalProfilesSnapshot> _create(
  ServerAccountController account,
  RemoteProfile desired,
  String requestId,
) async {
  final before = await _list(account);
  late CorePersonalProfileMutation mutation;
  await account.withSession((api, session) async {
    mutation = await CorePersonalProfilesApi(
      api,
      session.accessToken,
      session.context!,
      session.user.id,
      current: () => true,
      requestId: () => requestId,
    ).create(desired, before);
  });
  return account.withSession(
    (api, session) => CorePersonalProfilesApi(
      api,
      session.accessToken,
      session.context!,
      session.user.id,
      current: () => true,
    ).list(expectedAuthority: mutation.authority),
  );
}

Future<CorePersonalProfilesSnapshot> _delete(
  ServerAccountController account,
  CorePersonalProfilesSnapshot before,
  String requestId,
) async {
  late CorePersonalProfileMutation mutation;
  await account.withSession((api, session) async {
    mutation = await CorePersonalProfilesApi(
      api,
      session.accessToken,
      session.context!,
      session.user.id,
      current: () => true,
      requestId: () => requestId,
    ).delete(before.profiles.single, before);
  });
  return account.withSession(
    (api, session) => CorePersonalProfilesApi(
      api,
      session.accessToken,
      session.context!,
      session.user.id,
      current: () => true,
    ).list(expectedAuthority: mutation.authority),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final coreUrl = Platform.environment['LARENOR_F61_F62_CORE_URL'];
  final enabled = coreUrl != null && coreUrl.isNotEmpty;
  late FlutterSecureStoragePlatform previous;
  final secure = <String, String>{};

  setUpAll(() {
    HttpOverrides.global = null;
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final arguments = call.arguments as Map;
            final key = arguments['key'] as String;
            return switch (call.method) {
              'read' => secure[key],
              'write' => () {
                secure[key] = arguments['value'] as String;
              }(),
              'delete' => () {
                secure.remove(key);
              }(),
              _ => throw StateError('unexpected_secure_storage_call'),
            };
          },
        );
  });
  tearDownAll(() {
    FlutterSecureStoragePlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test(
    'normal Core scopes RDP and VNC stores and retires them without replay',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'F61 F62 Core conjunction',
      );
      expect(account.failure, isNull);
      expect((await _list(account)).profiles, isEmpty);

      var rdpSnapshot = await _create(
        account,
        RemoteProfile(
          id: '6' * 32,
          name: 'Owned RDP fixture',
          protocol: RemoteProtocol.rdp,
          host: '127.0.0.1',
          port: 3389,
          username: 'larenor',
        ),
        '6' * 32,
      );
      final rdpAuthority = CoreManagedProfileAuthority(
        account: account,
        profile: rdpSnapshot.profiles.single,
        authority: rdpSnapshot.authority,
        ownerCurrent: () => true,
      );
      addTearDown(rdpAuthority.dispose);
      await rdpAuthority.start();
      final rdpStore = rdpAuthority.createRdpSecurityStore();
      final rdpProfile = rdpSnapshot.profiles.single.profile;
      const rdpPin = RdpCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      await rdpStore.trust(
        rdpProfile,
        rdpPin,
        isCurrent: () => rdpAuthority.isCurrent,
      );
      await rdpStore.saveCredential(
        rdpProfile,
        const RdpCredential(password: 'synthetic-rdp-private'),
        isCurrent: () => rdpAuthority.isCurrent,
      );
      expect(
        await rdpStore.readPin(
          rdpProfile,
          isCurrent: () => rdpAuthority.isCurrent,
        ),
        rdpPin,
      );

      rdpSnapshot = await _delete(account, rdpSnapshot, '7' * 32);
      expect(rdpSnapshot.profiles, isEmpty);
      await rdpStore.forgetProfileRecords(
        rdpProfile,
        isCurrent: () => rdpAuthority.isCurrent,
      );

      final vncSnapshot = await _create(
        account,
        RemoteProfile(
          id: '8' * 32,
          name: 'Owned VNC fixture',
          protocol: RemoteProtocol.vnc,
          host: '127.0.0.1',
          port: 5900,
          username: '',
        ),
        '8' * 32,
      );
      final vncAuthority = CoreManagedProfileAuthority(
        account: account,
        profile: vncSnapshot.profiles.single,
        authority: vncSnapshot.authority,
        ownerCurrent: () => true,
      );
      addTearDown(vncAuthority.dispose);
      await vncAuthority.start();
      final vncStore = vncAuthority.createVncSecurityStore();
      const vncPin = VncCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      );
      await vncStore.trust(
        vncSnapshot.profiles.single.profile,
        vncPin,
        isCurrent: () => vncAuthority.isCurrent,
      );
      var retireNotifications = 0;
      vncAuthority.addListener(() => retireNotifications++);
      await account.signOut();
      expect(vncAuthority.isCurrent, isFalse);
      expect(retireNotifications, 1);
      vncAuthority.retire();
      expect(retireNotifications, 1);
      await expectLater(
        vncStore.readPin(
          vncSnapshot.profiles.single.profile,
          isCurrent: () => vncAuthority.isCurrent,
        ),
        throwsA(
          isA<VncFailure>().having(
            (failure) => failure.code,
            'code',
            'retired',
          ),
        ),
      );
      expect(
        secure.keys.any((key) => key.startsWith('rdp_')),
        isFalse,
        reason: secure.keys.where((key) => key.startsWith('rdp_')).join('\n'),
      );
      expect(secure.keys.where((key) => key.startsWith('vnc_')).length, 1);
    },
    skip: enabled ? false : 'Run with server/tests/support/core_managed_desktop_flutter_acceptance.py.',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
