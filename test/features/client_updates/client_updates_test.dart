import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/client_updates/data/client_release_repository.dart';
import 'package:larenor/features/client_updates/data/client_update_api.dart';
import 'package:larenor/features/client_updates/data/client_update_controller.dart';
import 'package:larenor/features/client_updates/domain/client_update_models.dart';

Map<String, Object> releaseJson() => {
  'schemaVersion': 1,
  'applicationId': ClientRelease.applicationId,
  'versionCode': 20,
  'versionName': '2.0',
  'certificateSha256': 'a' * 64,
  'apkSha256': 'b' * 64,
  'sizeBytes': 100,
  'minSdk': 26,
  'commit': 'c' * 40,
  'downloadPath': '/api/v1/client/releases/20/apk',
  'publishedAt': '2026-09-05T10:00:00Z',
  'releaseNotes': 'Synthetic release',
};
Map<String, Object> installedJson({bool permission = true}) => {
  'supported': true,
  'applicationId': ClientRelease.applicationId,
  'versionCode': 19,
  'versionName': '1.9',
  'certificateSha256': ['a' * 64],
  'sdkInt': 35,
  'canRequestPackageInstalls': permission,
  'resumed': true,
  'focused': true,
  'interactionEpoch': 7,
};
Matcher fails(ClientUpdateFailure failure) => throwsA(
  isA<ClientUpdateException>().having(
    (e) => e.failure,
    'typed failure',
    failure,
  ),
);

class FakeApi extends ClientUpdateApi {
  final events = StreamController<ClientUpdateProgress>.broadcast(sync: true);
  int downloads = 0, installs = 0, cancels = 0, invalidations = 0, settings = 0;
  String? session, downloadId;
  Completer<StagedClientUpdate>? pending;
  Completer<InstalledClientSnapshot>? pendingSnapshot;
  bool permission = true;
  @override
  Stream<ClientUpdateProgress> get progress => events.stream;
  @override
  Future<void> activateSession(String sessionId) async {
    session = sessionId;
  }

  @override
  Future<InstalledClientSnapshot> snapshot() async => pendingSnapshot == null
      ? InstalledClientSnapshot.fromChannel(
          installedJson(permission: permission),
        )
      : await pendingSnapshot!.future;
  @override
  Future<StagedClientUpdate> download({
    required String sessionId,
    required String downloadId,
    required String baseUrl,
    required String accessToken,
    required ClientRelease release,
    required int interactionEpoch,
  }) async {
    downloads++;
    this.downloadId = downloadId;
    return pending == null ? staged(downloadId) : await pending!.future;
  }

  StagedClientUpdate staged([String? id]) => StagedClientUpdate(
    id: id ?? downloadId!,
    versionCode: 20,
    sizeBytes: 100,
  );
  @override
  Future<void> cancel(String sessionId) async {
    cancels++;
  }

  @override
  Future<void> invalidate(String sessionId) async {
    invalidations++;
  }

  @override
  Future<ClientInstallOutcome> install(
    String sessionId,
    StagedClientUpdate staged, {
    required int interactionEpoch,
  }) async {
    installs++;
    return ClientInstallOutcome.systemPromptOpened;
  }

  @override
  Future<void> openInstallPermission(
    String sessionId, {
    required int interactionEpoch,
  }) async {
    settings++;
  }
}

void main() {
  group('release contract', () {
    test(
      'bounded manifest roundtrip and installed current-signer comparison',
      () {
        final release = ClientRelease.fromJson(releaseJson());
        expect(ClientRelease.fromJson(release.toJson()).versionCode, 20);
        expect(
          InstalledClientSnapshot.fromChannel(installedJson()).accepts(release),
          isTrue,
        );
        expect(
          InstalledClientSnapshot.fromChannel({
            ...installedJson(),
            'versionCode': 20,
          }).accepts(release),
          isFalse,
        );
        expect(
          InstalledClientSnapshot.fromChannel({
            ...installedJson(),
            'certificateSha256': ['c' * 64],
          }).accepts(release),
          isFalse,
        );
        expect(
          InstalledClientSnapshot.fromChannel({
            ...installedJson(),
            'certificateSha256': ['a' * 64, 'c' * 64],
          }).accepts(release),
          isFalse,
        );
      },
    );
    for (final change in <Map<String, Object>>[
      {'schemaVersion': 2},
      {'applicationId': 'other.app'},
      {'sizeBytes': ClientRelease.maxBytes + 1},
      {'sizeBytes': 0},
      {'versionCode': 20.5},
      {'minSdk': 25},
      {'commit': 'invalid'},
      {'downloadPath': '//attacker.example/apk'},
      {'downloadPath': '/api/v1/client/releases/20/%2e%2e/apk'},
      {'certificateSha256': 'bad'},
      {'publishedAt': '2026-09-05'},
      {'releaseNotes': 'x' * 12001},
      {'extra': 'field'},
    ]) {
      test('invalid ${change.keys.first} fails before native/network', () {
        expect(
          () => ClientRelease.fromJson({...releaseJson(), ...change}),
          fails(ClientUpdateFailure.invalidMetadata),
        );
      });
    }
  });

  group('read-only release repository', () {
    test(
      'exact server prefix, authorization and GET; no APK requested',
      () async {
        var calls = 0;
        final repository = ClientReleaseRepository(
          baseUrl: 'http://127.0.0.1:8124/proxy/',
          accessToken: 'synthetic-session',
          clientFactory: () => MockClient((request) async {
            calls++;
            expect(request.method, 'GET');
            expect(request.followRedirects, isFalse);
            expect(
              request.url.toString(),
              'http://127.0.0.1:8124/proxy/api/v1/client/releases/latest?platform=android&channel=stable',
            );
            expect(
              request.headers['Authorization'],
              'Bearer synthetic-session',
            );
            return http.Response(jsonEncode(releaseJson()), 200);
          }),
        );
        addTearDown(repository.close);
        expect((await repository.latest())!.versionCode, 20);
        expect(calls, 1);
      },
    );
    test(
      '204 means no release, denied/malformed/oversized do not mean empty',
      () async {
        for (final entry in <(http.Response, ClientUpdateFailure?)>[
          (http.Response('', 204), null),
          (
            http.Response('private response', 401),
            ClientUpdateFailure.authentication,
          ),
          (
            http.Response('private response', 403),
            ClientUpdateFailure.permission,
          ),
          (http.Response('not json', 200), ClientUpdateFailure.invalidMetadata),
          (
            http.Response('x' * 65537, 200),
            ClientUpdateFailure.invalidMetadata,
          ),
        ]) {
          final repository = ClientReleaseRepository(
            baseUrl: 'http://127.0.0.1',
            accessToken: 'synthetic-session',
            clientFactory: () => MockClient((_) async => entry.$1),
          );
          try {
            if (entry.$2 == null) {
              expect(await repository.latest(), isNull);
            } else {
              await expectLater(repository.latest(), fails(entry.$2!));
            }
          } finally {
            repository.close();
          }
        }
      },
    );
    test('account changes reject a late successful manifest', () async {
      var current = true;
      final response = Completer<http.Response>();
      final repository = ClientReleaseRepository(
        baseUrl: 'http://127.0.0.1',
        accessToken: 'synthetic-session',
        isCurrent: () => current,
        clientFactory: () => MockClient((_) => response.future),
      );
      final load = repository.latest();
      final assertion = expectLater(load, fails(ClientUpdateFailure.expired));
      current = false;
      response.complete(http.Response(jsonEncode(releaseJson()), 200));
      await assertion;
      repository.close();
    });
    test(
      'redirect is rejected without accepting a new origin or body',
      () async {
        var calls = 0;
        final repository = ClientReleaseRepository(
          baseUrl: 'http://127.0.0.1',
          accessToken: 'synthetic-session',
          clientFactory: () => MockClient((_) async {
            calls++;
            return http.Response(
              '',
              302,
              headers: {'location': 'https://other.example/'},
            );
          }),
        );
        await expectLater(
          repository.latest(),
          fails(ClientUpdateFailure.network),
        );
        expect(calls, 1);
        repository.close();
      },
    );
  });

  group('explicit session-bound update controller', () {
    late FakeApi api;
    late ClientUpdateController controller;
    late bool accountCurrent;
    setUp(() {
      api = FakeApi();
      accountCurrent = true;
      controller = ClientUpdateController(
        api,
        ClientUpdateSource(
          baseUrl: 'http://127.0.0.1',
          accessToken: 'synthetic-session',
          isCurrent: () => accountCurrent,
        ),
      );
    });
    tearDown(() async {
      controller.dispose();
      await api.events.close();
    });
    test('construction and visibility never check, download or install automatically', () {
      controller.setVisible(true);
      expect(api.downloads, 0);
      expect(api.installs, 0);
      expect(api.session, isNull);
    });
    test('download validates and stages; fresh separate action opens one system prompt', () async {
      controller.setVisible(true);
      await controller.download(ClientRelease.fromJson(releaseJson()));
      expect(controller.phase, ClientUpdatePhase.ready);
      expect(api.installs, 0);
      expect(
        await controller.install(),
        ClientInstallOutcome.systemPromptOpened,
      );
      expect(api.installs, 1);
      expect(controller.staged, isNull);
      await expectLater(
        controller.install(),
        fails(ClientUpdateFailure.expired),
      );
      expect(api.installs, 1);
    });
    test(
      'duplicate download and foreign or older progress are rejected',
      () async {
        controller.setVisible(true);
        api.pending = Completer();
        final load = controller.download(ClientRelease.fromJson(releaseJson()));
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          controller.download(ClientRelease.fromJson(releaseJson())),
          fails(ClientUpdateFailure.busy),
        );
        api.events.add(
          ClientUpdateProgress(
            sessionId: api.session!,
            downloadId: 'old-download',
            receivedBytes: 50,
            totalBytes: 100,
            phase: ClientUpdateTransferPhase.downloading,
          ),
        );
        expect(controller.transfer, isNull);
        api.events.add(
          ClientUpdateProgress(
            sessionId: api.session!,
            downloadId: api.downloadId!,
            receivedBytes: 50,
            totalBytes: 100,
            phase: ClientUpdateTransferPhase.downloading,
          ),
        );
        expect(controller.transfer!.receivedBytes, 50);
        api.events.add(
          ClientUpdateProgress(
            sessionId: api.session!,
            downloadId: api.downloadId!,
            receivedBytes: 10,
            totalBytes: 100,
            phase: ClientUpdateTransferPhase.downloading,
          ),
        );
        expect(controller.transfer!.receivedBytes, 50);
        api.pending!.complete(api.staged());
        await load;
        expect(api.downloads, 1);
      },
    );
    test('idle/background retires pending response; wake never revives an install handle', () async {
      controller.setVisible(true);
      api.pending = Completer();
      final load = controller.download(ClientRelease.fromJson(releaseJson()));
      final assertion = expectLater(load, fails(ClientUpdateFailure.expired));
      await Future<void>.delayed(Duration.zero);
      controller.setVisible(false);
      controller.setVisible(true);
      api.pending!.complete(api.staged());
      await assertion;
      expect(controller.staged, isNull);
      expect(controller.phase, ClientUpdatePhase.idle);
      expect(api.cancels, greaterThan(0));
    });
    test(
      'old account snapshot cannot dispatch download on new account',
      () async {
        controller.setVisible(true);
        api.pendingSnapshot = Completer();
        final load = controller.download(ClientRelease.fromJson(releaseJson()));
        final assertion = expectLater(load, fails(ClientUpdateFailure.expired));
        await Future<void>.delayed(Duration.zero);
        accountCurrent = false;
        api.pendingSnapshot!.complete(
          InstalledClientSnapshot.fromChannel(installedJson()),
        );
        await assertion;
        expect(api.downloads, 0);
        expect(api.installs, 0);
      },
    );
    test(
      'unknown-source permission is explicit and return does not install',
      () async {
        controller.setVisible(true);
        await controller.download(ClientRelease.fromJson(releaseJson()));
        api.permission = false;
        await expectLater(
          controller.install(),
          fails(ClientUpdateFailure.installPermission),
        );
        expect(api.installs, 0);
        await controller.openInstallPermission();
        controller.setVisible(false);
        controller.setVisible(true);
        expect(api.settings, 1);
        expect(api.installs, 0);
        expect(controller.staged, isNotNull);
        api.permission = true;
        await controller.install();
        expect(api.installs, 1);
      },
    );
    test(
      'logout drops staged metadata and issues scoped native invalidation',
      () async {
        controller.setVisible(true);
        await controller.download(ClientRelease.fromJson(releaseJson()));
        accountCurrent = false;
        controller.invalidate();
        expect(controller.staged, isNull);
        expect(controller.release, isNull);
        expect(api.invalidations, 1);
        await expectLater(
          controller.install(),
          fails(ClientUpdateFailure.expired),
        );
        expect(api.installs, 0);
      },
    );
  });

  group('actual method-channel contract', () {
    const channel = MethodChannel('test/client_updates');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));
    test(
      'unsupported never calls platform and no fake supported snapshot',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return null;
        });
        final api = AndroidClientUpdateApi(methods: channel, isAndroid: false);
        expect((await api.snapshot()).supported, isFalse);
        await expectLater(
          api.openInstallPermission('synthetic-session', interactionEpoch: 7),
          fails(ClientUpdateFailure.unsupported),
        );
        expect(calls, 0);
      },
    );
    test('native error details never escape and installation result is only system prompt', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'install') return {'outcome': 'systemPromptOpened'};
        throw PlatformException(
          code: 'verification',
          message: 'private endpoint token',
          details: 'private file',
        );
      });
      final api = AndroidClientUpdateApi(methods: channel, isAndroid: true);
      try {
        await api.snapshot();
        fail('Expected native rejection');
      } on ClientUpdateException catch (e) {
        expect(e.failure, ClientUpdateFailure.verification);
        expect(e.toString(), 'Client update unavailable');
      }
      expect(
        await api.install(
          'synthetic-session',
          const StagedClientUpdate(
            id: '00000000-0000-4000-8000-000000000000',
            versionCode: 20,
            sizeBytes: 100,
          ),
          interactionEpoch: 7,
        ),
        ClientInstallOutcome.systemPromptOpened,
      );
    });
  });
}
