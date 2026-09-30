import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:larenor/features/remote_access/core/core_managed_profile_authority.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles.dart';
import 'package:larenor/features/remote_access/core/core_personal_profiles_api.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/sftp_controller.dart';
import 'package:larenor/features/remote_access/ssh/sftp_engine.dart';
import 'package:larenor/features/remote_access/ssh/sftp_file_access.dart';
import 'package:larenor/features/remote_access/ssh/ssh_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/ssh/ssh_session_controller.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_controller.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_models.dart';
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

Future<void> _wait(bool Function() ready, [String code = 'timed_out']) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(code);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
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
      requestId: () => 'f' * 32,
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

Future<CorePersonalProfilesSnapshot> _rename(
  ServerAccountController account,
  CorePersonalProfilesSnapshot before,
) async {
  final target = before.profiles.single;
  late CorePersonalProfileMutation mutation;
  await account.withSession((api, session) async {
    mutation =
        await CorePersonalProfilesApi(
          api,
          session.accessToken,
          session.context!,
          session.user.id,
          current: () => true,
          requestId: () => 'e' * 32,
        ).update(
          target,
          RemoteProfile(
            id: target.id,
            name: 'Core target after drift',
            protocol: target.profile.protocol,
            host: target.profile.host,
            port: target.profile.port,
            username: target.profile.username,
          ),
          before,
        );
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
) async {
  late CorePersonalProfileMutation mutation;
  await account.withSession((api, session) async {
    mutation = await CorePersonalProfilesApi(
      api,
      session.accessToken,
      session.context!,
      session.user.id,
      current: () => true,
      requestId: () => 'd' * 32,
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

final class _LiveTransports {
  const _LiveTransports({
    required this.authority,
    required this.shell,
    required this.sftp,
    required this.tunnel,
  });

  final CoreManagedProfileAuthority authority;
  final SshSessionController shell;
  final SftpController sftp;
  final SshTunnelController tunnel;
}

Future<String> _readTunnel(int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/'))
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, HttpStatus.ok);
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

Future<_LiveTransports> _connect(
  ServerAccountController account,
  CorePersonalProfilesSnapshot snapshot,
  String privateKey,
  String passphrase,
  String hostKeyType,
  String fingerprint,
  String sftpRoot,
  int tunnelPort,
  int targetPort,
) async {
  final authority = CoreManagedProfileAuthority(
    account: account,
    profile: snapshot.profiles.single,
    authority: snapshot.authority,
    ownerCurrent: () => true,
    // Keep the gate faster than production's three-second poll without
    // manufacturing a request flood that the normal Core correctly limits.
    refreshInterval: const Duration(milliseconds: 250),
  );
  await authority.start();
  final store = authority.createSecurityStore();
  await store.saveCredential(
    snapshot.profiles.single.profile,
    SshCredential(
      SshCredentialKind.privateKey,
      privateKey,
      passphrase: passphrase,
    ),
    isCurrent: () => authority.isCurrent,
  );
  final shell = SshSessionController(
    profile: snapshot.profiles.single.profile,
    store: store,
    engineFactory: DartSshEngine.new,
    isCurrent: () => authority.isCurrent,
  );
  final sftp = SftpController(
    profile: snapshot.profiles.single.profile,
    store: store,
    engineFactory: DartSftpEngine.new,
    fileAccess: SftpFileAccess(
      pickFile: () async => null,
      saveFile: (_, _) async => null,
    ),
    isCurrent: () => authority.isCurrent,
  );
  final tunnel = SshTunnelController(
    profile: snapshot.profiles.single.profile,
    store: store,
    engineFactory: DartSshTunnelEngine.new,
    isCurrent: () => authority.isCurrent,
  );
  authority.addListener(() {
    if (!authority.isCurrent) {
      shell.retire();
      sftp.retire();
      tunnel.retire();
    }
  });
  final opening = shell.connect();
  await _wait(() => shell.phase == SshSessionPhase.hostKey, 'host_key');
  expect(shell.pendingPin?.type, hostKeyType);
  expect(shell.pendingPin?.fingerprint, fingerprint);
  await shell.trustHost();
  await opening;
  expect(shell.phase, SshSessionPhase.connected, reason: shell.error);

  await sftp.connect();
  expect(sftp.phase, SftpPhase.ready, reason: sftp.error);
  await sftp.openDirectory(sftpRoot);
  expect(sftp.phase, SftpPhase.ready, reason: sftp.error);
  expect(sftp.entries.map((entry) => entry.name), contains('hello.txt'));
  expect(authority.isCurrent, isTrue, reason: 'authority retired after SFTP');

  await tunnel.save(
    SshTunnelProfile.parse(
      name: 'Core-managed fixture',
      localPort: '$tunnelPort',
      targetHost: '127.0.0.1',
      targetPort: '$targetPort',
    ),
  );
  expect(tunnel.phase, SshTunnelPhase.ready, reason: tunnel.error);
  await tunnel.start();
  expect(
    tunnel.phase,
    SshTunnelPhase.active,
    reason:
        'tunnel=${tunnel.error}; authority=${authority.isCurrent}; '
        'shell=${shell.phase}; sftp=${sftp.phase}',
  );
  expect(await _readTunnel(tunnelPort), 'Larenor tunnel fixture\n');

  addTearDown(() {
    shell.dispose();
    sftp.dispose();
    tunnel.dispose();
    authority.dispose();
  });
  return _LiveTransports(
    authority: authority,
    shell: shell,
    sftp: sftp,
    tunnel: tunnel,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final coreUrl = Platform.environment['LARENOR_F63_CORE_URL'];
  final phase = Platform.environment['LARENOR_F63_PHASE'];
  final statePath = Platform.environment['LARENOR_F63_STATE_FILE'];
  final keyPath = Platform.environment['LARENOR_SSH_PRIVATE_KEY'];
  final commandLog = Platform.environment['LARENOR_F63_COMMAND_LOG'];
  final sftpRoot = Platform.environment['LARENOR_SFTP_FIXTURE_ROOT'];
  final port = int.tryParse(
    Platform.environment['LARENOR_SSH_FIXTURE_PORT'] ?? '',
  );
  final tunnelPort = int.tryParse(
    Platform.environment['LARENOR_SSH_TUNNEL_PORT'] ?? '',
  );
  final targetPort = int.tryParse(
    Platform.environment['LARENOR_SSH_TARGET_PORT'] ?? '',
  );
  final enabled =
      [
        coreUrl,
        phase,
        statePath,
        keyPath,
        commandLog,
        sftpRoot,
        Platform.environment['LARENOR_SSH_KEY_PASSPHRASE'],
        Platform.environment['LARENOR_SSH_HOST_KEY_TYPE'],
        Platform.environment['LARENOR_SSH_HOST_KEY_FINGERPRINT'],
      ].every((value) => value != null && value.isNotEmpty) &&
      port != null &&
      tunnelPort != null &&
      targetPort != null;
  late FlutterSecureStoragePlatform previous;
  final secure = <String, String>{};
  var failSecureDelete = false;
  var secureDeleteCalls = 0;

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
                secureDeleteCalls++;
                if (failSecureDelete) {
                  throw PlatformException(code: 'private');
                }
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
    'normal Core authority retires actual SSH after drift and restart revoke',
    () async {
      final stateFile = File(statePath!);
      ServerSession? restored;
      if (phase == 'session') {
        final storage =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        storage['baseUrl'] = coreUrl;
        restored = ServerSession.decodeStorage(jsonEncode(storage));
      }
      final account = ServerAccountController(store: _Store(restored));
      addTearDown(account.dispose);
      if (restored == null) {
        await account.signIn(
          baseUrl: coreUrl!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'F63 acceptance',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);

      var snapshot = await _list(account);
      if (phase == 'profile') {
        expect(snapshot.profiles, isEmpty);
        snapshot = await _create(
          account,
          RemoteProfile(
            id: '1' * 32,
            name: 'Owned OpenSSH target',
            protocol: RemoteProtocol.ssh,
            host: '127.0.0.1',
            port: port!,
            username: Platform.environment['LARENOR_SSH_FIXTURE_USER']!,
          ),
        );
      } else {
        expect(snapshot.profiles, hasLength(1));
      }
      final live = await _connect(
        account,
        snapshot,
        await File(keyPath!).readAsString(),
        Platform.environment['LARENOR_SSH_KEY_PASSPHRASE']!,
        Platform.environment['LARENOR_SSH_HOST_KEY_TYPE']!,
        Platform.environment['LARENOR_SSH_HOST_KEY_FINGERPRINT']!,
        sftpRoot!,
        tunnelPort!,
        targetPort!,
      );
      final marker = phase == 'profile' ? 'profile-drift' : 'session-revoke';
      await live.shell.sendLine(
        "printf '$marker\\n' >> '$commandLog'; printf 'started\\n'; while true; do printf 'tick\\n'; sleep 1; done",
      );
      await _wait(() => live.shell.transcript.contains('started'), 'command');

      if (phase == 'profile') {
        await _rename(account, snapshot);
        await _wait(
          () =>
              live.shell.phase == SshSessionPhase.closed &&
              live.sftp.phase == SftpPhase.closed &&
              live.tunnel.phase == SshTunnelPhase.closed,
          'profile_not_retired',
        );
        await stateFile.writeAsString(account.session!.encodeStorage());
      } else {
        await account.signOut();
        await _wait(
          () =>
              live.shell.phase == SshSessionPhase.closed &&
              live.sftp.phase == SftpPhase.closed &&
              live.tunnel.phase == SshTunnelPhase.closed,
          'session_not_retired',
        );
      }
      expect(live.shell.error, isNull);
      expect(live.sftp.error, isNull);
      expect(live.tunnel.error, isNull);
    },
    skip: !enabled || !{'profile', 'session'}.contains(phase)
        ? 'Run with server/tests/support/f63_flutter_acceptance.py.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'normal Core DELETE readback precedes explicit exact local cleanup retry',
    () async {
      final account = ServerAccountController(store: _Store(null));
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'F63 cleanup acceptance',
      );
      expect(account.failure, isNull);

      final before = await _list(account);
      expect(before.profiles, hasLength(1));
      final authority = CoreManagedProfileAuthority(
        account: account,
        profile: before.profiles.single,
        authority: before.authority,
        ownerCurrent: () => true,
      );
      addTearDown(authority.dispose);
      final store = authority.createSecurityStore();

      final after = await _delete(account, before);
      expect(after.profiles, isEmpty);
      expect(after.collectionRevision, before.collectionRevision + 1);

      failSecureDelete = true;
      await expectLater(
        store.forgetProfileRecords(
          before.profiles.single.profile,
          isCurrent: () => authority.isCurrent,
        ),
        throwsA(
          isA<SshFailure>().having(
            (failure) => failure.code,
            'code',
            'storage_failed',
          ),
        ),
      );
      expect(secureDeleteCalls, 1);

      failSecureDelete = false;
      await store.forgetProfileRecords(
        before.profiles.single.profile,
        isCurrent: () => authority.isCurrent,
      );
      expect(secureDeleteCalls, 4);
      expect((await _list(account)).profiles, isEmpty);
    },
    skip: !enabled || phase != 'cleanup'
        ? 'Run with server/tests/support/f63_flutter_acceptance.py.'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
