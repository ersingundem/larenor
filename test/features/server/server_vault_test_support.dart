import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/backup_restore_access.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

class VaultRestoreAccess implements BackupRestoreAccess {
  VaultRestoreAccess({this.isCurrent});
  final bool Function()? isCurrent;
  @override
  HomeSource get source => HomeSource.directLocal;
  @override
  Map<String, dynamic> get ownership => {'source': source.name};
  @override
  DateTime get validUntil => DateTime.now().add(const Duration(hours: 1));
  @override
  void checkLive() {
    if (isCurrent?.call() == false) {
      throw const BackupException('restore_expired', 'Read the preview again.');
    }
  }
  @override
  Future<void> checkDurable() async {}
}

ServerSession vaultSession({DateTime? expires, bool mustChange = false}) =>
    ServerSession(
      endpoint: ServerEndpoint('https://fixture.invalid'),
      accessToken: 'synthetic_access_12345678',
      refreshToken: 'synthetic_refresh_12345678',
      expiresAt: expires ?? DateTime.now().add(const Duration(days: 1)),
      user: ServerUser(
        id: 'fixture',
        username: 'Fixture',
        role: ServerRole.member,
        mustChangePassword: mustChange,
      ),
    );

class VaultAccountStore implements ServerSessionPersistence {
  VaultAccountStore({ServerSession? value}) : value = value ?? vaultSession();
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async {
    value = session;
  }
}

BackupSnapshot vaultSnapshot({bool legacy = false}) => BackupSnapshot.fromJson({
  'version': legacy ? 1 : 2,
  'createdAt': '2026-09-05T08:00:00.000Z',
  'groups': {
    'settings': {'appearance': 'dark'},
    'dashboard': {
      'rooms': [],
      'tiles': [],
      'favoriteEntityIds': ['light.fixture'],
      'hiddenEntityIds': [],
    },
    'connections': {
      'ha': {
        'baseUrl': 'https://private-fixture.invalid',
        'token': 'synthetic_private_ha_secret',
      },
      'proxmox': {
        'host': 'private-proxmox.invalid',
        'port': '8006',
        'username': 'secret_fixture_user',
        'realm': 'pam',
        'password': 'synthetic_proxmox_secret',
        'allowSelfSigned': 'true',
      },
    },
    if (!legacy)
      'privacy': {
        'version': 1,
        'entityIds': ['sensor.private_fixture'],
        'reviewRequired': true,
      },
  },
});

class VaultApi extends LarenorServerApi {
  VaultApi()
    : super(
        endpoint: ServerEndpoint('https://fixture.invalid'),
        client: MockClient((_) async => http.Response('{}', 500)),
      );
  ServerVault value = ServerVault(revision: 7, snapshot: vaultSnapshot());
  int reads = 0, writes = 0, refreshes = 0;
  int? expectedRevision;
  BackupSnapshot? uploaded;
  Completer<ServerVault>? pendingRead, pendingWrite;
  Completer<ServerSession>? pendingRefresh;
  String? writeError, readError;
  @override
  Future<ServerContext> context(String accessToken) async =>
      ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
      });
  @override
  Future<ServerUser> me(String accessToken) async => vaultSession().user;
  @override
  Future<void> logout(ServerSession session) async {}
  @override
  Future<ServerSession> refresh(String token) async {
    refreshes++;
    return pendingRefresh?.future ?? Future.value(vaultSession());
  }

  @override
  Future<ServerVault> readVault(String token) async {
    reads++;
    if (readError case final error?) throw LarenorServerException(error);
    return pendingRead?.future ?? Future.value(value);
  }

  @override
  Future<ServerVault> writeVault({
    required String accessToken,
    required int expectedRevision,
    required BackupSnapshot snapshot,
  }) async {
    writes++;
    this.expectedRevision = expectedRevision;
    uploaded = snapshot;
    if (writeError case final error?) throw LarenorServerException(error);
    if (pendingWrite case final pending?) return pending.future;
    if (expectedRevision != value.revision) {
      throw const LarenorServerException('revision_conflict');
    }
    value = ServerVault(revision: expectedRevision + 1, snapshot: snapshot);
    return value;
  }
}
