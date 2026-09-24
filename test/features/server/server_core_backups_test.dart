import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;
import 'package:larenor/features/server/core_backups/data/server_core_backups_controller.dart';
import 'package:larenor/features/server/core_backups/domain/server_core_backup_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_admin_test_support.dart';

Map<String, dynamic> backupManifest() => {
  'contractVersion': 2,
  'snapshotId': '1' * 32,
  'createdAt': 1789952400,
  'coreVersion': '0.5.0',
  'databaseSchemaVersion': 61,
  'componentSchemaVersions': {'auth': 1, 'vault': 1, 'jellyfin': 1},
  'components': [
    {
      'serviceId': 'jellyfin',
      'serviceVersion': '10.11.11',
      'configSchemaVersion': 1,
      'dataSchemaVersion': 'upstream_managed_unverified',
      'volumeResourceIds': [
        'component-jellyfin-cache',
        'component-jellyfin-config',
      ],
    },
  ],
  'consistencyBoundary': {
    'mode': 'core_write_lock_and_component_quiescence',
    'maxDurationSeconds': 5,
  },
  'resources': [
    {
      'id': 'component-index',
      'kind': 'componentData',
      'version': '2',
      'byteLength': 80,
      'sha256': '1' * 64,
    },
    {
      'id': 'component-jellyfin-cache',
      'kind': 'componentData',
      'version': 'component-v1',
      'byteLength': 250,
      'sha256': '6' * 64,
    },
    {
      'id': 'component-jellyfin-config',
      'kind': 'componentData',
      'version': 'component-v1',
      'byteLength': 350,
      'sha256': '7' * 64,
    },
    {
      'id': 'core-configuration',
      'kind': 'configuration',
      'version': '1',
      'byteLength': 120,
      'sha256': '2' * 64,
    },
    {
      'id': 'core-database',
      'kind': 'database',
      'version': '61',
      'byteLength': 4096,
      'sha256': '3' * 64,
    },
    {
      'id': 'family-board',
      'kind': 'familyBoard',
      'version': '1',
      'byteLength': 1024,
      'sha256': '5' * 64,
    },
    {
      'id': 'vault-key',
      'kind': 'vaultKey',
      'version': 'aes256-v1',
      'byteLength': 32,
      'sha256': '4' * 64,
    },
  ],
};

Map<String, dynamic> readyPlan() => {
  'status': 'ready',
  'blockers': <String>[],
  'manifest': backupManifest(),
};

Map<String, dynamic> manifestWithResourceLength(String id, int byteLength) => {
  ...backupManifest(),
  'resources': [
    for (final raw
        in (backupManifest()['resources']! as List)
            .cast<Map<String, dynamic>>())
      if (raw['id'] == id) {...raw, 'byteLength': byteLength} else raw,
  ],
};

Map<String, dynamic> manifestWithComponentLengths(List<int> byteLengths) {
  final original = backupManifest();
  final fixedResources = (original['resources']! as List)
      .cast<Map<String, dynamic>>()
      .where(
        (item) => !(item['id'] as String).startsWith('component-jellyfin-'),
      )
      .toList();
  final components = <Map<String, dynamic>>[];
  final volumeResources = <Map<String, dynamic>>[];
  for (var component = 0; component * 3 < byteLengths.length; component++) {
    final start = component * 3;
    final end = (start + 3).clamp(0, byteLengths.length);
    final serviceId = 'service$component';
    final ids = <String>[];
    for (var index = start; index < end; index++) {
      final id = 'component-$serviceId-volume$index';
      ids.add(id);
      volumeResources.add({
        'id': id,
        'kind': 'componentData',
        'version': 'component-v1',
        'byteLength': byteLengths[index],
        'sha256': '${component + 1}' * 64,
      });
    }
    components.add({
      'serviceId': serviceId,
      'serviceVersion': '1.0.0',
      'configSchemaVersion': 1,
      'dataSchemaVersion': '1',
      'volumeResourceIds': ids,
    });
  }
  return {
    ...original,
    'components': components,
    'resources': [...fixedResources, ...volumeResources],
  };
}

final class BackupFixture extends AdminFixture {
  BackupFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/context')) {
        return defaultResponse(request);
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/admin/backups/plan')) {
        return pending?.future ?? json(response);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/admin/backups/export')) {
        return exportPending?.future ??
            http.Response.bytes(
              bundle,
              200,
              headers: {
                'content-type': 'application/vnd.larenor.core-backup',
                'content-disposition':
                    'attachment; filename="larenor-core-backup.larenor-core"',
                'cache-control': 'no-store',
                'x-content-type-options': 'nosniff',
                'x-larenor-capture-generation': '1' * 32,
              },
            );
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/admin/backups/restore/validate')) {
        return validationPending?.future ?? json(validationResponse);
      }
      return json({
        'error': {'code': 'not_found'},
      }, 404);
    };
  }

  Map<String, dynamic> response = readyPlan();
  Map<String, dynamic> validationResponse = {
    'compatible': true,
    'reasons': <String>[],
  };
  Uint8List bundle = Uint8List.fromList([
    ...utf8.encode('LARENOR-CORE-BACKUP\u0000\u0001'),
    ...List<int>.filled(64, 7),
  ]);
  Completer<http.Response>? pending;
  Completer<http.Response>? exportPending;
  Completer<http.Response>? validationPending;
}

class BackupDestinationFixture implements LarenorBinaryDestination {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  bool cancelled = false;
  bool committed = false;
  int maxChunk = 0;
  Uint8List get bytes => _bytes.toBytes();

  @override
  Future<void> add(Uint8List bytes) async {
    if (cancelled || committed) throw StateError('closed');
    maxChunk = bytes.length > maxChunk ? bytes.length : maxChunk;
    _bytes.add(bytes);
  }

  @override
  Future<Uri> commit({required int byteLength, required String sha256}) async {
    final value = bytes;
    expect(byteLength, value.length);
    expect(sha256, crypto.sha256.convert(value).toString());
    committed = true;
    return Uri.parse('content://larenor-test/export');
  }

  @override
  Future<void> cancel() async => cancelled = true;
}

class StreamingClient extends http.BaseClient {
  StreamingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

final class _PendingJsonRequest {
  _PendingJsonRequest(this.request, {required this.holdAbort});

  final http.BaseRequest request;
  final bool holdAbort;
  final response = Completer<http.StreamedResponse>();
  final abortSeen = Completer<void>();
  final abortRelease = Completer<void>();

  Future<http.StreamedResponse> run() {
    final abortTrigger = (request as http.AbortableRequest).abortTrigger!;
    final aborted = abortTrigger.then<http.StreamedResponse>((_) async {
      if (!abortSeen.isCompleted) abortSeen.complete();
      if (holdAbort) await abortRelease.future;
      throw http.RequestAbortedException(request.url);
    });
    return Future.any([response.future, aborted]);
  }

  void completeJson(Object value) {
    final body = utf8.encode(jsonEncode(value));
    response.complete(
      http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
        headers: {'content-type': 'application/json'},
      ),
    );
  }
}

final class _AbortAwareBackupClient extends http.BaseClient {
  final requests = <_PendingJsonRequest>[];
  final _nextRequest = StreamController<_PendingJsonRequest>.broadcast();
  bool holdNextAbort = false;

  Future<_PendingJsonRequest> nextRequest() => _nextRequest.stream.first;

  http.StreamedResponse _json(Object value) {
    final body = utf8.encode(jsonEncode(value));
    return http.StreamedResponse(
      Stream.value(body),
      200,
      contentLength: body.length,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/auth/me')) {
      return _json({
        'user': {
          'id': adminId,
          'username': 'admin',
          'role': 'admin',
          'mustChangePassword': false,
        },
      });
    }
    if (request.url.path.endsWith('/context')) {
      return _json({
        'schemaVersion': 1,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
      });
    }
    final pending = _PendingJsonRequest(request, holdAbort: holdNextAbort);
    holdNextAbort = false;
    requests.add(pending);
    _nextRequest.add(pending);
    return pending.run();
  }

  @override
  void close() {
    _nextRequest.close();
  }
}

Future<ServerAccountController> _abortAwareAccount(
  _AbortAwareBackupClient client,
) async {
  final now = DateTime.utc(2026, 9, 5, 9);
  final user = ServerUser(
    id: adminId,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  );
  final store = AdminStore(
    ServerSession(
      endpoint: ServerEndpoint('https://fixture.invalid/prefix'),
      accessToken: 'synthetic_admin_access_12345',
      refreshToken: 'synthetic_admin_refresh_12345',
      expiresAt: now.add(const Duration(hours: 1)),
      user: user,
    ),
  );
  final account = ServerAccountController(
    store: store,
    clock: () => now,
    apiFactory: (endpoint) =>
        LarenorServerApi(endpoint: endpoint, client: client, clock: () => now),
  );
  await account.initialize();
  return account;
}

class CountingDestination implements LarenorBinaryDestination {
  int bytes = 0;
  int maxChunk = 0;
  bool cancelled = false;
  bool committed = false;
  Completer<void>? addGate;
  final Completer<void> addStarted = Completer<void>();

  @override
  Future<void> add(Uint8List value) async {
    if (!addStarted.isCompleted) addStarted.complete();
    await addGate?.future;
    bytes += value.length;
    maxChunk = value.length > maxChunk ? value.length : maxChunk;
  }

  @override
  Future<Uri> commit({required int byteLength, required String sha256}) async {
    expect(byteLength, bytes);
    expect(sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    committed = true;
    return Uri.parse('content://larenor-test/counting');
  }

  @override
  Future<void> cancel() async => cancelled = true;
}

Map<String, String> exportHeaders({String? generation = '11111111111111111111111111111111'}) => {
  'content-type': 'application/vnd.larenor.core-backup',
  'content-disposition':
      'attachment; filename="larenor-core-backup.larenor-core"',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  if (generation != null) 'x-larenor-capture-generation': generation,
};

LarenorServerApi directApi(http.Client client, {Duration? timeout}) =>
    LarenorServerApi(
      endpoint: ServerEndpoint('https://fixture.invalid/prefix'),
      client: client,
      timeout: timeout ?? const Duration(seconds: 20),
    );

void main() {
  test('plan parser accepts only exact bounded backup metadata', () {
    final plan = CoreBackupPlan.fromJson(readyPlan());
    expect(plan.ready, isTrue);
    expect(plan.manifest!.totalBytes, 5952);
    expect(plan.manifest!.components.single.serviceVersion, '10.11.11');
    expect(plan.manifest!.components.single.volumeResourceIds.length, 2);
    expect(plan.manifest!.consistencyBoundary!.maxDurationSeconds, 5);
    expect(plan.manifest!.resources.map((item) => item.kind), {
      CoreBackupResourceKind.componentData,
      CoreBackupResourceKind.configuration,
      CoreBackupResourceKind.database,
      CoreBackupResourceKind.familyBoard,
      CoreBackupResourceKind.vaultKey,
    });
    expect(plan.toString(), isNot(contains('111111111')));
    expect(plan.manifest.toString(), 'CoreBackupManifest');

    final blocked = CoreBackupPlan.fromJson({
      'status': 'blocked',
      'blockers': ['active_plugin_job'],
      'manifest': null,
    });
    expect(blocked.ready, isFalse);

    for (final invalid in <Map<String, dynamic>>[
      {...readyPlan(), 'secret': 'leak'},
      {...readyPlan(), 'status': 'blocked'},
      {
        ...readyPlan(),
        'blockers': ['unknown_operation'],
      },
      {
        ...readyPlan(),
        'manifest': {...backupManifest(), 'contractVersion': 3},
      },
      {
        ...readyPlan(),
        'manifest': {
          ...backupManifest(),
          'resources': [
            for (final item in backupManifest()['resources']! as List)
              if ((item as Map)['id'] == 'vault-key')
                {...item, 'version': 'plaintext'}
              else
                item,
          ],
        },
      },
    ]) {
      expect(
        () => CoreBackupPlan.fromJson(invalid),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test('legacy four-resource Core backup remains readable', () {
    final current = backupManifest();
    final legacy = <String, dynamic>{
      for (final entry in current.entries)
        if (entry.key != 'components' && entry.key != 'consistencyBoundary')
          entry.key: entry.value,
      'contractVersion': 1,
      'resources': [
        for (final raw
            in (current['resources']! as List).cast<Map<String, dynamic>>())
          if (raw['id'] != 'family-board' &&
              !(raw['id'] as String).startsWith('component-jellyfin-'))
            if (raw['id'] == 'component-index')
              {...raw, 'version': '1'}
            else
              raw,
      ],
    };
    final plan = CoreBackupManifest.fromJson(legacy);
    expect(plan.resources.length, 4);
    expect(plan.totalBytes, 4328);
  });

  test('contract v1 rejects component-era fields', () {
    final current = backupManifest();
    final malformed = <String, dynamic>{
      ...current,
      'contractVersion': 1,
      'resources': [
        for (final raw
            in (current['resources']! as List).cast<Map<String, dynamic>>())
          if (raw['id'] != 'family-board') raw,
      ],
    };

    expect(
      () => CoreBackupManifest.fromJson(malformed),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('contract v2 requires component contract fields', () {
    final current = backupManifest();
    final malformed = <String, dynamic>{
      for (final entry in current.entries)
        if (entry.key != 'components' && entry.key != 'consistencyBoundary')
          entry.key: entry.value,
      'resources': [
        for (final raw
            in (current['resources']! as List).cast<Map<String, dynamic>>())
          if (!(raw['id'] as String).startsWith('component-jellyfin-'))
            if (raw['id'] == 'component-index')
              {...raw, 'version': '1'}
            else
              raw,
      ],
    };

    expect(
      () => CoreBackupManifest.fromJson(malformed),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('contract v2 rejects a null consistency boundary', () {
    final current = backupManifest();
    final malformed = <String, dynamic>{
      ...current,
      'components': <Object>[],
      'consistencyBoundary': null,
      'resources': [
        for (final raw
            in (current['resources']! as List).cast<Map<String, dynamic>>())
          if (!(raw['id'] as String).startsWith('component-jellyfin-'))
            if (raw['id'] == 'component-index')
              {...raw, 'version': '1'}
            else
              raw,
      ],
    };

    expect(
      () => CoreBackupManifest.fromJson(malformed),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test('manifest requires an exact 32-byte AES-256 vault key', () {
    expect(
      () => CoreBackupManifest.fromJson(backupManifest()),
      returnsNormally,
    );
    for (final invalidLength in [31, 33]) {
      expect(
        () => CoreBackupManifest.fromJson(
          manifestWithResourceLength('vault-key', invalidLength),
        ),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test('manifest enforces each database and component resource cap', () {
    for (final (id, maximum) in [
      ('core-database', 128 * 1024 * 1024),
      ('family-board', 32 * 1024 * 1024),
      ('component-jellyfin-cache', 64 * 1024 * 1024),
    ]) {
      expect(
        () => CoreBackupManifest.fromJson(
          manifestWithResourceLength(id, maximum),
        ),
        returnsNormally,
      );
      expect(
        () => CoreBackupManifest.fromJson(
          manifestWithResourceLength(id, maximum + 1),
        ),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  test('manifest caps all managed component volumes at 256 MiB', () {
    const volumeCap = 64 * 1024 * 1024;
    expect(
      () => CoreBackupManifest.fromJson(
        manifestWithComponentLengths(List.filled(4, volumeCap)),
      ),
      returnsNormally,
    );
    expect(
      () => CoreBackupManifest.fromJson(
        manifestWithComponentLengths([...List.filled(4, volumeCap), 1]),
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });

  test(
    'controller binds the read to current admin session and visibility',
    () async {
      final fixture = BackupFixture();
      await fixture.account.initialize();
      final controller = ServerCoreBackupsController(fixture.account);
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });

      await controller.load(current: () => true);
      expect(controller.plan?.ready, isTrue);
      expect(fixture.adminCalls.single.method, 'GET');
      expect(fixture.mutations, isEmpty);
      expect(
        fixture.adminCalls.single.headers['authorization'],
        'Bearer synthetic_admin_access_12345',
      );

      fixture.response = {...readyPlan(), 'status': 'invalid'};
      await controller.load(current: () => true);
      expect(controller.plan, isNull);
      expect(controller.failure, 'invalid_response');

      fixture.pending = Completer<http.Response>();
      final pending = controller.load(current: () => true);
      controller.invalidate();
      fixture.pending!.complete(
        fixture.json({
          'status': 'blocked',
          'blockers': ['active_plugin_job'],
          'manifest': null,
        }),
      );
      await pending;
      expect(controller.plan, isNull);
      expect(controller.failure, isNull);
    },
  );

  test('invalidate aborts the in-flight backup plan transport', () async {
    final client = _AbortAwareBackupClient();
    final account = await _abortAwareAccount(client);
    final controller = ServerCoreBackupsController(account);
    addTearDown(() {
      controller.dispose();
      account.dispose();
    });

    final requestStarted = client.nextRequest();
    final loading = controller.load(current: () => true);
    final request = await requestStarted;

    controller.invalidate();

    await request.abortSeen.future.timeout(const Duration(seconds: 1));
    await loading.timeout(const Duration(seconds: 1));
    expect(controller.busy, isFalse);
    expect(controller.plan, isNull);
    expect(controller.failure, isNull);
  });

  test('dispose aborts the in-flight restore preflight transport', () async {
    final client = _AbortAwareBackupClient();
    final account = await _abortAwareAccount(client);
    final controller = ServerCoreBackupsController(account);
    addTearDown(account.dispose);

    final requestStarted = client.nextRequest();
    final preflight = controller.preflight(
      CoreBackupManifest.fromJson(backupManifest()),
      current: () => true,
    );
    final request = await requestStarted;

    controller.dispose();

    await request.abortSeen.future.timeout(const Duration(seconds: 1));
    await preflight.timeout(const Duration(seconds: 1));
  });

  test('retired request cleanup cannot abort a newer plan request', () async {
    final client = _AbortAwareBackupClient()..holdNextAbort = true;
    final account = await _abortAwareAccount(client);
    final controller = ServerCoreBackupsController(account);
    addTearDown(() {
      controller.dispose();
      account.dispose();
    });

    var requestStarted = client.nextRequest();
    final firstLoad = controller.load(current: () => true);
    final firstRequest = await requestStarted;
    controller.invalidate();
    await firstRequest.abortSeen.future.timeout(const Duration(seconds: 1));

    requestStarted = client.nextRequest();
    final secondLoad = controller.load(current: () => true);
    final secondRequest = await requestStarted;
    firstRequest.abortRelease.complete();
    await firstLoad.timeout(const Duration(seconds: 1));
    expect(secondRequest.abortSeen.isCompleted, isFalse);

    secondRequest.completeJson(readyPlan());
    await secondLoad.timeout(const Duration(seconds: 1));
    expect(controller.plan?.ready, isTrue);
  });

  test('member account cannot dispatch backup readiness reads', () async {
    final fixture = BackupFixture();
    fixture.user = ServerUser(
      id: adminId,
      username: 'member',
      role: ServerRole.member,
      mustChangePassword: false,
    );
    fixture.store.value = fixture.session();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    await controller.load(current: () => true);
    expect(fixture.adminCalls, isEmpty);
    expect(controller.plan, isNull);
  });

  test('export keeps passphrase in the fixed body and returns only bounded ciphertext', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    const passphrase = 'Synthetic export passphrase 2026';

    final destination = BackupDestinationFixture();
    final secret = LarenorRequestSecret.coreBackup(passphrase);
    final exported = await controller.export(
      secret,
      destination,
      current: () => true,
    );

    expect(destination.bytes, fixture.bundle);
    expect(destination.maxChunk, lessThanOrEqualTo(64 * 1024));
    expect(exported!.byteLength, fixture.bundle.length);
    expect(exported.captureGeneration, '1' * 32);
    expect(exported.destination, Uri.parse('content://larenor-test/export'));
    final request = fixture.adminCalls.single;
    expect(request.url.path, endsWith('/admin/backups/export'));
    expect(request.url.query, isEmpty);
    expect(jsonDecode(request.body), {'passphrase': passphrase});
    expect(request.headers['authorization'], startsWith('Bearer '));
    expect(secret.disposed, isTrue);
    expect(controller.toString(), isNot(contains(passphrase)));
    expect(exported.toString(), isNot(contains(passphrase)));
  });

  test('export accepts 424 MiB cap as bounded reused chunks', () async {
    const maxBytes = 424 * 1024 * 1024;
    expect(LarenorServerApi.maxCoreBackupBytes, maxBytes);
    expect(
      LarenorServerApi.coreBackupOverallTimeout,
      const Duration(minutes: 15),
    );
    const chunkBytes = 64 * 1024;
    final zero = Uint8List(chunkBytes);
    final first = Uint8List(chunkBytes);
    first.setAll(0, utf8.encode('LARENOR-CORE-BACKUP\u0000\u0001'));
    final client = StreamingClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          first,
          for (var offset = chunkBytes; offset < maxBytes; offset += chunkBytes)
            zero,
        ]),
        200,
        contentLength: maxBytes,
        headers: exportHeaders(),
      ),
    );
    final api = directApi(client);
    final destination = CountingDestination();
    addTearDown(api.close);

    final receipt = await api.exportCoreBackup(
      token: 'synthetic-token',
      passphrase: LarenorRequestSecret.coreBackup(
        'Synthetic export passphrase 2026',
      ),
      destination: destination,
      cancellation: LarenorTransferCancellation(),
    );

    expect(receipt.byteLength, maxBytes);
    expect(destination.bytes, maxBytes);
    expect(destination.maxChunk, chunkBytes);
    expect(destination.committed, isTrue);
    expect(destination.cancelled, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'declared overflow and exact-length mismatch delete partial output',
    () async {
      const maxBytes = 424 * 1024 * 1024;
      final overflowDestination = CountingDestination();
      final overflowApi = directApi(
        StreamingClient(
          (_) async => http.StreamedResponse(
            const Stream<List<int>>.empty(),
            200,
            contentLength: maxBytes + 1,
            headers: exportHeaders(),
          ),
        ),
      );
      addTearDown(overflowApi.close);
      await expectLater(
        overflowApi.exportCoreBackup(
          token: 'synthetic-token',
          passphrase: LarenorRequestSecret.coreBackup(
            'Synthetic export passphrase 2026',
          ),
          destination: overflowDestination,
          cancellation: LarenorTransferCancellation(),
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      expect(overflowDestination.cancelled, isTrue);
      expect(overflowDestination.committed, isFalse);

      final body = Uint8List.fromList([
        ...utf8.encode('LARENOR-CORE-BACKUP\u0000\u0001'),
        ...List<int>.filled(64, 7),
      ]);
      final mismatchDestination = CountingDestination();
      final mismatchApi = directApi(
        StreamingClient(
          (_) async => http.StreamedResponse(
            Stream.value(body),
            200,
            contentLength: body.length + 1,
            headers: exportHeaders(),
          ),
        ),
      );
      addTearDown(mismatchApi.close);
      await expectLater(
        mismatchApi.exportCoreBackup(
          token: 'synthetic-token',
          passphrase: LarenorRequestSecret.coreBackup(
            'Synthetic export passphrase 2026',
          ),
          destination: mismatchDestination,
          cancellation: LarenorTransferCancellation(),
        ),
        throwsA(isA<LarenorServerException>()),
      );
      expect(mismatchDestination.bytes, body.length);
      expect(mismatchDestination.cancelled, isTrue);
      expect(mismatchDestination.committed, isFalse);
    },
  );

  test('missing or malformed generation receipt deletes partial output', () async {
    final body = Uint8List.fromList([
      ...utf8.encode('LARENOR-CORE-BACKUP\u0000\u0001'),
      ...List<int>.filled(64, 7),
    ]);
    for (final generation in <String?>[null, '2' * 31, 'G' * 32]) {
      final destination = CountingDestination();
      final api = directApi(
        StreamingClient(
          (_) async => http.StreamedResponse(
            Stream.value(body),
            200,
            contentLength: body.length,
            headers: exportHeaders(generation: generation),
          ),
        ),
      );
      addTearDown(api.close);

      await expectLater(
        api.exportCoreBackup(
          token: 'synthetic-token',
          passphrase: LarenorRequestSecret.coreBackup(
            'Synthetic export passphrase 2026',
          ),
          destination: destination,
          cancellation: LarenorTransferCancellation(),
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      expect(destination.cancelled, isTrue);
      expect(destination.committed, isFalse);
    }
  });

  test(
    'cancellation closes the response stream and blocks late add commit',
    () async {
      final streamCancelled = Completer<void>();
      final stream = StreamController<List<int>>(
        onCancel: () {
          if (!streamCancelled.isCompleted) streamCancelled.complete();
        },
      );
      final destination = CountingDestination()..addGate = Completer<void>();
      final cancellation = LarenorTransferCancellation();
      final secret = LarenorRequestSecret.coreBackup(
        'Synthetic export passphrase 2026',
      );
      final api = directApi(
        StreamingClient(
          (_) async => http.StreamedResponse(
            stream.stream,
            200,
            headers: exportHeaders(),
          ),
        ),
        timeout: const Duration(seconds: 1),
      );
      addTearDown(api.close);
      final export = api.exportCoreBackup(
        token: 'synthetic-token',
        passphrase: secret,
        destination: destination,
        cancellation: cancellation,
      );
      stream.add(
        Uint8List.fromList([
          ...utf8.encode('LARENOR-CORE-BACKUP\u0000\u0001'),
          ...List<int>.filled(64, 7),
        ]),
      );
      await destination.addStarted.future;

      cancellation.cancel();
      await expectLater(
        export,
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await streamCancelled.future;
      destination.addGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(secret.disposed, isTrue);
      expect(destination.cancelled, isTrue);
      expect(destination.committed, isFalse);
    },
  );

  test('error response always cancels the uncommitted destination', () async {
    final destination = CountingDestination();
    final api = directApi(
      StreamingClient(
        (_) async => http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"code":"invalid_request"}}')),
          400,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.exportCoreBackup(
        token: 'synthetic-token',
        passphrase: LarenorRequestSecret.coreBackup(
          'Synthetic export passphrase 2026',
        ),
        destination: destination,
        cancellation: LarenorTransferCancellation(),
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );

    expect(destination.cancelled, isTrue);
    expect(destination.committed, isFalse);
  });

  test(
    'send failure scrubs mutable request buffers and cancels output',
    () async {
      Uint8List? requestBody;
      Uint8List? observedBody;
      final client = StreamingClient((request) async {
        requestBody = request is http.Request ? request.bodyBytes : null;
        observedBody = requestBody == null
            ? null
            : Uint8List.fromList(requestBody!);
        throw http.ClientException('synthetic transport failure');
      });
      final api = directApi(client);
      final destination = CountingDestination();
      final secret = LarenorRequestSecret.coreBackup(
        'Synthetic export passphrase 2026',
      );
      addTearDown(api.close);

      await expectLater(
        api.exportCoreBackup(
          token: 'synthetic-token',
          passphrase: secret,
          destination: destination,
          cancellation: LarenorTransferCancellation(),
        ),
        throwsA(isA<LarenorServerException>()),
      );

      expect(jsonDecode(utf8.decode(observedBody!)), {
        'passphrase': 'Synthetic export passphrase 2026',
      });
      expect(requestBody, everyElement(0));
      expect(secret.disposed, isTrue);
      expect(destination.cancelled, isTrue);
    },
  );

  test(
    'abort before response headers stays cancelled and scrubs body',
    () async {
      final requestSeen = Completer<void>();
      final response = Completer<http.StreamedResponse>();
      Uint8List? requestBody;
      final api = directApi(
        StreamingClient((request) {
          requestBody = (request as http.Request).bodyBytes;
          requestSeen.complete();
          return response.future;
        }),
        timeout: const Duration(seconds: 1),
      );
      final destination = CountingDestination();
      final secret = LarenorRequestSecret.coreBackup(
        'Synthetic export passphrase 2026',
      );
      final cancellation = LarenorTransferCancellation();
      addTearDown(api.close);

      final export = api.exportCoreBackup(
        token: 'synthetic-token',
        passphrase: secret,
        destination: destination,
        cancellation: cancellation,
      );
      await requestSeen.future;
      cancellation.cancel();

      await expectLater(
        export,
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(requestBody, everyElement(0));
      expect(secret.disposed, isTrue);
      expect(destination.cancelled, isTrue);
    },
  );

  test(
    'restore preflight exposes exact incompatibility reasons without restore',
    () async {
      final fixture = BackupFixture()
        ..validationResponse = {
          'compatible': false,
          'reasons': [
            'unsupported_contract_version',
            'core_version_mismatch',
            'database_schema_mismatch',
            'component_schema_mismatch',
            'component_version_mismatch',
            'component_volume_mismatch',
          ],
        };
      await fixture.account.initialize();
      final controller = ServerCoreBackupsController(fixture.account);
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });
      final manifest = CoreBackupManifest.fromJson(backupManifest());

      await controller.preflight(manifest, current: () => true);

      expect(controller.compatibility!.compatible, isFalse);
      expect(controller.compatibility!.reasons, {
        CoreBackupCompatibilityReason.unsupportedContract,
        CoreBackupCompatibilityReason.coreVersion,
        CoreBackupCompatibilityReason.databaseSchema,
        CoreBackupCompatibilityReason.componentSchema,
        CoreBackupCompatibilityReason.componentVersion,
        CoreBackupCompatibilityReason.componentVolume,
      });
      final request = fixture.adminCalls.single;
      expect(request.url.path, endsWith('/admin/backups/restore/validate'));
      expect(request.url.query, isEmpty);
      expect(jsonDecode(request.body), {'manifest': backupManifest()});
      expect(
        fixture.adminCalls.where(
          (call) => !call.url.path.endsWith('/restore/validate'),
        ),
        isEmpty,
      );
    },
  );

  test('retired route drops delayed export and preflight results', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    fixture.exportPending = Completer<http.Response>();
    final destination = BackupDestinationFixture();
    final export = controller.export(
      LarenorRequestSecret.coreBackup('Synthetic export passphrase 2026'),
      destination,
      current: () => true,
    );
    controller.invalidate();
    fixture.exportPending!.complete(
      http.Response.bytes(
        fixture.bundle,
        200,
        headers: {
          'content-type': 'application/vnd.larenor.core-backup',
          'content-disposition':
              'attachment; filename="larenor-core-backup.larenor-core"',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        },
      ),
    );
    expect(await export, isNull);
    expect(destination.cancelled, isTrue);

    fixture.exportPending = null;
    fixture.validationPending = Completer<http.Response>();
    final preflight = controller.preflight(
      CoreBackupManifest.fromJson(backupManifest()),
      current: () => true,
    );
    controller.invalidate();
    fixture.validationPending!.complete(
      fixture.json({'compatible': true, 'reasons': <String>[]}),
    );
    await preflight;
    expect(controller.compatibility, isNull);
    expect(controller.actionFailure, isNull);
  });

  test('invalid passphrase is rejected before any admin request', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    expect(
      () => LarenorRequestSecret.coreBackup('too short'),
      throwsA(isA<LarenorServerException>()),
    );
    expect(fixture.adminCalls, isEmpty);
  });

  test('binary envelope headers and compatibility shape fail closed', () async {
    final fixture = BackupFixture();
    await fixture.account.initialize();
    final controller = ServerCoreBackupsController(fixture.account);
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/admin/backups/export')) {
        return http.Response.bytes(
          fixture.bundle,
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }
      return fixture.json({
        'compatible': false,
        'reasons': ['unknown_mismatch'],
      });
    };
    expect(
      await controller.export(
        LarenorRequestSecret.coreBackup('Synthetic export passphrase 2026'),
        BackupDestinationFixture(),
        current: () => true,
      ),
      isNull,
    );
    expect(controller.actionFailure, 'invalid_response');

    fixture.respond = (request) async {
      if (request.url.path.endsWith('/admin/backups/export')) {
        return http.Response.bytes(
          Uint8List(80),
          200,
          headers: {
            'content-type': 'application/vnd.larenor.core-backup',
            'content-disposition':
                'attachment; filename="larenor-core-backup.larenor-core"',
            'cache-control': 'no-store',
            'x-content-type-options': 'nosniff',
          },
        );
      }
      return fixture.json({
        'compatible': false,
        'reasons': ['unknown_mismatch'],
      });
    };
    expect(
      await controller.export(
        LarenorRequestSecret.coreBackup('Synthetic export passphrase 2026'),
        BackupDestinationFixture(),
        current: () => true,
      ),
      isNull,
    );
    expect(controller.actionFailure, 'invalid_response');

    fixture.respond = (request) async {
      if (request.url.path.endsWith('/admin/backups/export')) {
        return fixture.json({
          'error': {'code': 'invalid_request'},
        }, 400);
      }
      return fixture.json({
        'compatible': false,
        'reasons': ['unknown_mismatch'],
      });
    };
    expect(
      await controller.export(
        LarenorRequestSecret.coreBackup('Synthetic export passphrase 2026'),
        BackupDestinationFixture(),
        current: () => true,
      ),
      isNull,
    );
    expect(controller.actionFailure, 'invalid_request');

    await controller.preflight(
      CoreBackupManifest.fromJson(backupManifest()),
      current: () => true,
    );
    expect(controller.compatibility, isNull);
    expect(controller.actionFailure, 'invalid_response');
  });
}
