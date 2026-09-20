import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_controller.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_file_access.dart';
import 'package:larenor/features/home_resources/data/core_bounded_upload_file_access.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

Uint8List _frame(
  String trace,
  int sequence,
  bool finalFrame,
  List<int> payload,
) {
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('LRB1'))
    ..add(ascii.encode(trace));
  final fields = ByteData(13)
    ..setUint64(0, sequence)
    ..setUint8(8, finalFrame ? 1 : 0)
    ..setUint32(9, payload.length);
  output
    ..add(fields.buffer.asUint8List())
    ..add(payload);
  return output.takeBytes();
}

http.Response _response({bool validDigest = true, int serviceRevision = 1}) {
  final payload = utf8.encode('verified fixture');
  final trace = 'c' * 32;
  final wire = Uint8List.fromList([
    ..._frame(trace, 0, false, payload),
    ..._frame(trace, 1, true, const []),
  ]);
  return http.Response.bytes(
    wire,
    200,
    headers: {
      'content-type': CoreBoundedDownloadApi.wireType,
      'content-length': '${wire.length}',
      'x-larenor-trace-id': trace,
      'x-larenor-blob-content-length': '${payload.length}',
      'x-larenor-blob-sha256': validDigest
          ? sha256.convert(payload).toString()
          : 'f' * 64,
      'x-larenor-blob-content-type': 'text/plain; charset=utf-8',
      'x-larenor-service-revision': '$serviceRevision',
      'x-larenor-resume-offset': '0',
      'accept-ranges': 'none',
    },
  );
}

Map<String, Object> _receipt({String? digest, int serviceRevision = 1}) {
  final payload = utf8.encode('verified fixture');
  return {
    'requestId': 'c' * 32,
    'traceId': 'c' * 32,
    'state': 'completed',
    'contentLength': payload.length,
    'sha256': digest ?? sha256.convert(payload).toString(),
    'contentType': 'text/plain; charset=utf-8',
    'serviceRevision': serviceRevision,
    'createdAt': 10.0,
    'updatedAt': 11.0,
  };
}

http.Response _verifiedResponse(
  http.Request request, {
  String? digest,
  int serviceRevision = 1,
}) {
  if (request.method == 'POST') {
    return _response(serviceRevision: serviceRevision);
  }
  if (request.url.path.endsWith('/descriptor')) {
    final payload = utf8.encode('verified fixture');
    final blobIndex = request.url.pathSegments.indexOf('blob');
    final resourceId = request.url.pathSegments[blobIndex - 1];
    return http.Response(
      jsonEncode({
        'blob': {
          'resourceId': resourceId,
          'serviceRevision': serviceRevision,
          'contentLength': payload.length,
          'sha256': sha256.convert(payload).toString(),
          'contentType': 'text/plain; charset=utf-8',
          'createdAt': 10.0,
          'updatedAt': 11.0,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  final receipt = _receipt(digest: digest, serviceRevision: serviceRevision);
  return http.Response(
    jsonEncode(
      request.url.path.endsWith('/${'c' * 32}')
          ? {'receipt': receipt}
          : {
              'receipts': [receipt],
            },
    ),
    200,
    headers: {'content-type': 'application/json'},
  );
}

final class _PendingClient extends http.BaseClient {
  final sent = Completer<void>();
  final release = Completer<void>();
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    if (!sent.isCompleted) sent.complete();
    await release.future;
    final seed = _response();
    return http.StreamedResponse(
      Stream.value(seed.bodyBytes),
      200,
      contentLength: seed.bodyBytes.length,
      headers: seed.headers,
      request: request,
    );
  }

  @override
  void close() {}
}

final class _FirstRequestGateClient extends http.BaseClient {
  _FirstRequestGateClient(this.respond)
    : _inner = MockClient((request) async => respond(request));

  final http.Response Function(http.Request request) respond;
  final http.Client _inner;
  final sent = Completer<void>();
  final release = Completer<void>();
  int requests = 0;
  int closes = 0;
  bool _gated = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    if (!_gated) {
      _gated = true;
      sent.complete();
      await release.future;
    }
    return _inner.send(request);
  }

  @override
  void close() {
    closes++;
  }
}

final class _CancelableResumeClient extends http.BaseClient {
  _CancelableResumeClient({this.deleteSucceeds = true});

  static const firstId = 'a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0';
  static const secondId = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
  static const finalId = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
  static final payload = Uint8List.fromList(utf8.encode('abcdefghi'));
  static final digest = sha256.convert(payload).toString();

  final bool deleteSucceeds;
  Completer<void>? _pendingCancel;
  int posts = 0, deletes = 0;

  Map<String, Object> receipt(String requestId, String state) => {
    'requestId': requestId,
    'traceId': requestId,
    'state': state,
    'contentLength': payload.length,
    'sha256': digest,
    'contentType': 'text/plain; charset=utf-8',
    'serviceRevision': 1,
    'createdAt': 10.0,
    'updatedAt': 11.0,
  };

  Map<String, String> headers(
    String trace,
    int framedLength,
    int resumeOffset,
  ) => {
    'content-type': CoreBoundedDownloadApi.wireType,
    'content-length': '$framedLength',
    'x-larenor-trace-id': trace,
    'x-larenor-blob-content-length': '${payload.length}',
    'x-larenor-blob-sha256': digest,
    'x-larenor-blob-content-type': 'text/plain; charset=utf-8',
    'x-larenor-service-revision': '1',
    'x-larenor-resume-offset': '$resumeOffset',
    'accept-ranges': 'none',
  };

  http.StreamedResponse jsonResponse(
    http.BaseRequest request,
    Object value, [
    int status = 200,
  ]) {
    final bytes = utf8.encode(jsonEncode(value));
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      contentLength: bytes.length,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/descriptor')) {
      return jsonResponse(request, {
        'blob': {
          'resourceId': '3' * 32,
          'serviceRevision': 1,
          'contentLength': payload.length,
          'sha256': digest,
          'contentType': 'text/plain; charset=utf-8',
          'createdAt': 10.0,
          'updatedAt': 11.0,
        },
      });
    }
    if (request.method == 'GET') {
      if (!deleteSucceeds && deletes > 0) {
        return jsonResponse(request, {
          'error': {'code': 'server_error'},
        }, 503);
      }
      final id = request.url.pathSegments.last;
      return jsonResponse(request, {
        'receipt': receipt(id, id == finalId ? 'completed' : 'interrupted'),
      });
    }
    if (request.method == 'DELETE') {
      deletes++;
      expect(request.url.query, isEmpty);
      expect(request.contentLength, 0);
      final id = request.url.pathSegments.last;
      if (!(_pendingCancel?.isCompleted ?? true)) _pendingCancel!.complete();
      return deleteSucceeds
          ? jsonResponse(request, {'receipt': receipt(id, 'interrupted')})
          : jsonResponse(request, {
              'error': {'code': 'server_error'},
            }, 503);
    }
    expect(request.method, 'POST');
    await request.finalize().drain<void>();
    final post = ++posts;
    if (post == 1) {
      final full = Uint8List.fromList([
        ..._frame(firstId, 0, false, utf8.encode('abc')),
        ..._frame(firstId, 1, false, utf8.encode('defghi')),
        ..._frame(firstId, 2, true, const []),
      ]);
      return http.StreamedResponse(
        Stream<List<int>>.multi((events) {
          events.add(_frame(firstId, 0, false, utf8.encode('abc')));
          events.add(
            _frame(firstId, 1, false, utf8.encode('defghi')).sublist(0, 51),
          );
          events.addError(const SocketException('synthetic interruption'));
          events.close();
        }),
        200,
        contentLength: full.length,
        headers: headers(firstId, full.length, 0),
        request: request,
      );
    }
    if (post == 2) {
      final full = Uint8List.fromList([
        ..._frame(secondId, 0, false, utf8.encode('def')),
        ..._frame(secondId, 1, false, utf8.encode('ghi')),
        ..._frame(secondId, 2, true, const []),
      ]);
      final cancelled = _pendingCancel = Completer<void>();
      return http.StreamedResponse(
        Stream<List<int>>.multi((events) async {
          events.add(_frame(secondId, 0, false, utf8.encode('def')));
          await cancelled.future;
          events.addError(const SocketException('synthetic cancel'));
          events.close();
        }),
        200,
        contentLength: full.length,
        headers: headers(secondId, full.length, 3),
        request: request,
      );
    }
    final wire = Uint8List.fromList([
      ..._frame(finalId, 0, false, utf8.encode('ghi')),
      ..._frame(finalId, 1, true, const []),
    ]);
    return http.StreamedResponse(
      Stream.value(wire),
      200,
      contentLength: wire.length,
      headers: headers(finalId, wire.length, 6),
      request: request,
    );
  }

  @override
  void close() {
    final pending = _pendingCancel;
    _pendingCancel = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}

HomeResourcePage _page() {
  final raw = contract();
  return HomeResourcePage.fromJson(
    raw['memberList'],
    expectedContext: ServerContext.fromJson(raw['context']),
  );
}

HomeResourcePage _writablePage() {
  final raw = contract();
  return HomeResourcePage.fromJson(
    raw['adminList'],
    expectedContext: ServerContext.fromJson(raw['context']),
  );
}

void main() {
  testWidgets(
    'verified interruption resumes, exact cancel readback resumes again, then publishes once',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      final client = _CancelableResumeClient();
      final requestIds = <String>[
        _CancelableResumeClient.firstId,
        _CancelableResumeClient.secondId,
        _CancelableResumeClient.finalId,
      ].iterator;
      var saves = 0;
      Uint8List? published;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          client: client,
          requestId: () {
            requestIds.moveNext();
            return requestIds.current;
          },
        ),
        CoreBoundedDownloadFileAccess(
          save: (_, _, bytes) async {
            saves++;
            published = Uint8List.fromList(bytes);
            return Uri.parse('content://synthetic/resumed');
          },
        ),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);

      await tester.runAsync(
        () => controller
            .download(
              target,
              userRevision: page.userRevision,
              isCurrent: () => true,
            )
            .timeout(const Duration(seconds: 2)),
      );
      expect(controller.phase, CoreBoundedDownloadPhase.interrupted);
      expect(controller.canResume(target, page.userRevision), isTrue);
      expect(controller.receiptTrusted, isTrue);
      expect(controller.providerAccepted, isFalse);
      expect(saves, 0);

      await tester.runAsync(() async {
        final resuming = controller.resume(
          target,
          userRevision: page.userRevision,
          isCurrent: () => true,
        );
        for (
          var attempt = 0;
          attempt < 20 && !controller.canCancel;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(controller.canCancel, isTrue);
        await controller.cancel(isCurrent: () => true);
        await resuming;
      });
      expect(client.deletes, 1);
      expect(controller.phase, CoreBoundedDownloadPhase.interrupted);
      expect(controller.canResume(target, page.userRevision), isTrue);
      expect(controller.receipt?.requestId, _CancelableResumeClient.secondId);
      expect(saves, 0);

      await tester.runAsync(
        () => controller
            .resume(
              target,
              userRevision: page.userRevision,
              isCurrent: () => true,
            )
            .timeout(const Duration(seconds: 2)),
      );
      expect(controller.phase, CoreBoundedDownloadPhase.saved);
      expect(controller.deviceResultObserved, isTrue);
      expect(published, _CancelableResumeClient.payload);
      expect(saves, 1);
      expect(client.posts, 3);
    },
  );

  testWidgets('failed cancel and readback discard partial evidence', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester);
    await harness.signIn();
    await flush(tester);
    final page = _page(), target = page.entries.last;
    final client = _CancelableResumeClient(deleteSucceeds: false);
    final requestIds = <String>[
      _CancelableResumeClient.firstId,
      _CancelableResumeClient.secondId,
    ].iterator;
    final controller = CoreBoundedDownloadController(
      harness.home(tester),
      (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        client: client,
        requestId: () {
          requestIds.moveNext();
          return requestIds.current;
        },
      ),
      CoreBoundedDownloadFileAccess(save: (_, _, _) async => null),
      () => harness.now,
      () => true,
    );
    addTearDown(controller.dispose);
    controller.setVisible(true);

    await tester.runAsync(
      () => controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      ),
    );
    expect(controller.canResume(target, page.userRevision), isTrue);
    await tester.runAsync(() async {
      final resuming = controller.resume(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      );
      for (var attempt = 0; attempt < 20 && !controller.canCancel; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(controller.canCancel, isTrue);
      await controller.cancel(isCurrent: () => true);
      await resuming;
    });
    expect(controller.canResume(target, page.userRevision), isFalse);
    expect(controller.receiptTrusted, isFalse);

    controller.retainAuthority(page.entries, page.userRevision + 1);
    expect(controller.phase, CoreBoundedDownloadPhase.idle);
    expect(controller.canResume(target, page.userRevision), isFalse);
    controller.setVisible(false);
    expect(controller.phase, CoreBoundedDownloadPhase.idle);
  });

  testWidgets(
    'verified partial is memory-only across lifecycle and revision retirement',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;

      Future<CoreBoundedDownloadController> interruptedController() async {
        final client = _CancelableResumeClient();
        final controller = CoreBoundedDownloadController(
          harness.home(tester),
          (endpoint) => CoreBoundedDownloadApi(
            endpoint: endpoint,
            client: client,
            requestId: () => _CancelableResumeClient.firstId,
          ),
          CoreBoundedDownloadFileAccess(
            save: (_, _, _) async => throw StateError('SAF must not run'),
          ),
          () => harness.now,
          () => true,
        );
        controller.setVisible(true);
        await tester.runAsync(
          () => controller.download(
            target,
            userRevision: page.userRevision,
            isCurrent: () => true,
          ),
        );
        expect(controller.phase, CoreBoundedDownloadPhase.interrupted);
        expect(controller.canResume(target, page.userRevision), isTrue);
        return controller;
      }

      final lifecycle = await interruptedController();
      lifecycle.setVisible(false);
      expect(lifecycle.phase, CoreBoundedDownloadPhase.idle);
      expect(lifecycle.canResume(target, page.userRevision), isFalse);
      lifecycle.dispose();

      final revision = await interruptedController();
      revision.retainAuthority(page.entries, page.userRevision + 1);
      expect(revision.phase, CoreBoundedDownloadPhase.idle);
      expect(revision.canResume(target, page.userRevision), isFalse);
      revision.dispose();
    },
  );

  testWidgets(
    'authorized member explicitly verifies then publishes once to SAF seam',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      var requests = 0, saves = 0;
      Uint8List? published;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          requestId: () => 'c' * 32,
          client: MockClient((request) async {
            requests++;
            if (request.method == 'POST') {
              expect(
                (jsonDecode(request.body) as Map)['expectedServiceRevision'],
                4,
              );
            }
            return _verifiedResponse(request, serviceRevision: 4);
          }),
        ),
        CoreBoundedDownloadFileAccess(
          save: (filename, type, bytes) async {
            saves++;
            expect(filename, 'larenor-resource-${target.id}.bin');
            expect(type, 'text/plain; charset=utf-8');
            published = Uint8List.fromList(bytes);
            return Uri.parse('content://synthetic/document');
          },
        ),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);
      expect(harness.account.session!.user.role, ServerRole.member);
      expect(controller.canDownload(target, page.userRevision), isTrue);

      await tester.runAsync(
        () => controller.download(
          target,
          userRevision: page.userRevision,
          isCurrent: () => true,
        ),
      );

      expect(controller.phase, CoreBoundedDownloadPhase.saved);
      expect(controller.intentRegistered, isTrue);
      expect(controller.serviceReachable, isTrue);
      expect(controller.providerAccepted, isTrue);
      expect(controller.deviceResultObserved, isTrue);
      expect(controller.receiptTrusted, isTrue);
      expect(controller.receipt?.state, CoreBoundedTransferState.completed);
      expect(controller.receipt?.serviceRevision, 4);
      expect(controller.traceId, 'c' * 32);
      expect(utf8.decode(published!), 'verified fixture');
      expect((requests, saves), (3, 1));
      await tester.runAsync(
        () => controller.download(
          page.entries.first,
          userRevision: page.userRevision,
          isCurrent: () => true,
        ),
      );
      expect(
        requests,
        3,
        reason: 'a room is never a binary download authority',
      );
      controller.retainAuthority(page.entries, page.userRevision + 1);
      expect(controller.phase, CoreBoundedDownloadPhase.idle);
      expect(controller.receiptTrusted, isFalse);
      expect(controller.receipt, isNull);
    },
  );

  testWidgets('invalid bytes never reach SAF and no automatic retry occurs', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester);
    await harness.signIn();
    await flush(tester);
    final page = _page(), target = page.entries.last;
    var requests = 0, saves = 0;
    final controller = CoreBoundedDownloadController(
      harness.home(tester),
      (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => 'c' * 32,
        client: MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/descriptor')) {
            return _verifiedResponse(request);
          }
          return _response(validDigest: false);
        }),
      ),
      CoreBoundedDownloadFileAccess(
        save: (_, _, _) async {
          saves++;
          return Uri.parse('content://must-not-run');
        },
      ),
      () => harness.now,
      () => true,
    );
    addTearDown(controller.dispose);
    controller.setVisible(true);
    await tester.runAsync(
      () => controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      ),
    );
    expect(controller.phase, CoreBoundedDownloadPhase.failed);
    expect(controller.intentRegistered, isTrue);
    expect(controller.serviceReachable, isTrue);
    expect(controller.providerAccepted, isFalse);
    expect(controller.deviceResultObserved, isFalse);
    expect((requests, saves), (2, 0));
  });

  testWidgets('cancelled SAF destination remains an explicit cancellation', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester);
    await harness.signIn();
    await flush(tester);
    final page = _page(), target = page.entries.last;
    var requests = 0, saves = 0;
    final controller = CoreBoundedDownloadController(
      harness.home(tester),
      (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => 'c' * 32,
        client: MockClient((request) async {
          requests++;
          return _verifiedResponse(request);
        }),
      ),
      CoreBoundedDownloadFileAccess(
        save: (_, _, _) async {
          saves++;
          return null;
        },
      ),
      () => harness.now,
      () => true,
    );
    addTearDown(controller.dispose);
    controller.setVisible(true);

    await tester.runAsync(
      () => controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      ),
    );

    expect(controller.phase, CoreBoundedDownloadPhase.cancelled);
    expect(controller.intentRegistered, isTrue);
    expect(controller.serviceReachable, isTrue);
    expect(controller.providerAccepted, isTrue);
    expect(controller.deviceResultObserved, isFalse);
    expect((requests, saves), (3, 1));
  });

  testWidgets('mismatched durable receipt never reaches SAF', (tester) async {
    final harness = ResourceHarness();
    await harness.mount(tester);
    await harness.signIn();
    await flush(tester);
    final page = _page(), target = page.entries.last;
    var requests = 0, saves = 0;
    final controller = CoreBoundedDownloadController(
      harness.home(tester),
      (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => 'c' * 32,
        client: MockClient((request) async {
          requests++;
          return _verifiedResponse(request, digest: 'f' * 64);
        }),
      ),
      CoreBoundedDownloadFileAccess(
        save: (_, _, _) async {
          saves++;
          return Uri.parse('content://must-not-run');
        },
      ),
      () => harness.now,
      () => true,
    );
    addTearDown(controller.dispose);
    controller.setVisible(true);

    await tester.runAsync(
      () => controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      ),
    );

    expect(controller.phase, CoreBoundedDownloadPhase.failed);
    expect(controller.receiptTrusted, isFalse);
    expect((requests, saves), (3, 0));
  });

  testWidgets(
    'lifecycle retirement closes pending request and rejects its late result',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      final pending = _PendingClient();
      var saves = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          requestId: () => 'c' * 32,
          client: pending,
        ),
        CoreBoundedDownloadFileAccess(
          save: (_, _, _) async {
            saves++;
            return Uri.parse('content://must-not-run');
          },
        ),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);
      expect(controller.canDownload(target, page.userRevision), isTrue);
      final future = controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      );
      await tester.pump();
      expect(pending.sent.isCompleted, isTrue);
      expect(controller.intentRegistered, isTrue);
      expect(controller.serviceReachable, isFalse);
      expect(controller.providerAccepted, isFalse);
      expect(controller.deviceResultObserved, isFalse);
      controller.setVisible(false);
      pending.release.complete();
      await tester.runAsync(() => future);
      expect(controller.phase, CoreBoundedDownloadPhase.idle);
      expect(controller.busy, isFalse);
      expect((pending.requests, saves), (1, 0));
    },
  );

  testWidgets(
    'resource or ACL refresh retires pending authority before publication',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      final pending = _PendingClient();
      var saves = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          requestId: () => 'c' * 32,
          client: pending,
        ),
        CoreBoundedDownloadFileAccess(
          save: (_, _, _) async {
            saves++;
            return Uri.parse('content://must-not-run');
          },
        ),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);
      final future = controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      );
      await tester.pump();
      expect(pending.sent.isCompleted, isTrue);
      controller.retainAuthority(const [], page.userRevision);
      pending.release.complete();
      await tester.runAsync(() => future);
      expect(controller.phase, CoreBoundedDownloadPhase.idle);
      expect(saves, 0);
    },
  );

  testWidgets(
    'account sign-out closes a pending transfer and rejects its late result',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      final pending = _PendingClient();
      var saves = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          requestId: () => 'c' * 32,
          client: pending,
        ),
        CoreBoundedDownloadFileAccess(
          save: (_, _, _) async {
            saves++;
            return Uri.parse('content://must-not-run');
          },
        ),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);
      final future = controller.download(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      );
      await tester.pump();
      expect(pending.sent.isCompleted, isTrue);

      await harness.account.signOut();
      pending.release.complete();
      await tester.runAsync(() => future);

      expect(controller.phase, CoreBoundedDownloadPhase.idle);
      expect(controller.busy, isFalse);
      expect((pending.requests, saves), (1, 0));
    },
  );

  testWidgets(
    'retired history completion cannot close a newer history transport',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      http.Response historyResponse(http.Request _) => http.Response(
        jsonEncode({
          'receipts': [_receipt()],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
      final firstClient = _FirstRequestGateClient(historyResponse);
      final secondClient = _FirstRequestGateClient(historyResponse);
      var factories = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          client: factories++ == 0 ? firstClient : secondClient,
        ),
        CoreBoundedDownloadFileAccess(save: (_, _, _) async => null),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);

      final firstFuture = controller.loadHistory(target, isCurrent: () => true);
      await tester.pump();
      expect(firstClient.sent.isCompleted, isTrue);

      controller.setVisible(false);
      controller.setVisible(true);
      expect(firstClient.closes, 1);

      final secondFuture = controller.loadHistory(
        target,
        isCurrent: () => true,
      );
      await tester.pump();
      expect(secondClient.sent.isCompleted, isTrue);
      expect(controller.historyPhase, CoreBoundedHistoryPhase.loading);

      firstClient.release.complete();
      await tester.runAsync(() => firstFuture);

      expect(secondClient.closes, 0);
      expect(controller.historyPhase, CoreBoundedHistoryPhase.loading);

      secondClient.release.complete();
      await tester.runAsync(() => secondFuture);

      expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
      expect(controller.history, hasLength(1));
      expect(secondClient.requests, 1);
      expect(secondClient.closes, 1);
    },
  );

  testWidgets(
    'authorized history is visible only while exact resource authority remains',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), target = page.entries.last;
      var requests = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          client: MockClient((request) async {
            requests++;
            expect(request.method, 'GET');
            return http.Response(
              jsonEncode({
                'receipts': [
                  {
                    'requestId': 'c' * 32,
                    'traceId': 'c' * 32,
                    'state': 'completed',
                    'contentLength': 16,
                    'sha256': 'd' * 64,
                    'contentType': 'text/plain',
                    'serviceRevision': 1,
                    'createdAt': 1789911000.0,
                    'updatedAt': 1789911001.0,
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        CoreBoundedDownloadFileAccess(save: (_, _, _) async => null),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);

      expect(controller.canLoadHistory(target), isTrue);
      await tester.runAsync(
        () => controller.loadHistory(target, isCurrent: () => true),
      );

      expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
      expect(controller.historyTargetId, target.id);
      expect(controller.history, hasLength(1));
      expect(requests, 1);

      controller.retainAuthority(const [], page.userRevision);
      expect(controller.historyPhase, CoreBoundedHistoryPhase.idle);
      expect(controller.history, isEmpty);
      expect(controller.historyTargetId, isNull);
    },
  );

  testWidgets('write-authorized picker creates the first product blob once', (
    tester,
  ) async {
    final harness = ResourceHarness();
    await harness.mount(tester);
    await harness.signIn();
    await flush(tester);
    final page = _writablePage();
    final target = page.entries.firstWhere(
      (entry) => entry.kind == HomeResourceKind.resource,
    );
    final bytes = Uint8List.fromList(utf8.encode('attached document'));
    var requests = 0;
    final controller = CoreBoundedDownloadController(
      harness.home(tester),
      (endpoint) => CoreBoundedDownloadApi(
        endpoint: endpoint,
        requestId: () => '8' * 32,
        client: MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/descriptor')) {
            return http.Response(
              '{"error":{"code":"not_found"}}',
              404,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(request.method, 'PUT');
          expect(request.headers['x-larenor-expected-service-revision'], '0');
          return http.Response(
            jsonEncode({
              'blob': {
                'requestId': '8' * 32,
                'resourceId': target.id,
                'serviceRevision': 1,
                'contentLength': bytes.length,
                'sha256': sha256.convert(bytes).toString(),
                'contentType': 'application/pdf',
                'createdAt': 10.0,
                'updatedAt': 10.0,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
      CoreBoundedDownloadFileAccess(save: (_, _, _) async => null),
      () => harness.now,
      () => true,
      CoreBoundedUploadFileAccess(
        pick: () async => CoreBoundedPickedFile(
          name: 'warranty.pdf',
          declaredLength: bytes.length,
          chunks: Stream.value(bytes),
        ),
      ),
    );
    addTearDown(controller.dispose);
    controller.setVisible(true);

    expect(
      controller.canUpload(_page().entries.last, page.userRevision),
      isFalse,
    );
    expect(controller.canUpload(target, page.userRevision), isTrue);
    await tester.runAsync(
      () => controller.chooseAndUpload(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      ),
    );

    expect(requests, 2);
    expect(controller.uploadPhase, CoreBoundedUploadPhase.uploaded);
    expect(controller.uploadRequestId, '8' * 32);
    expect(controller.descriptor?.serviceRevision, 1);
    expect(controller.busy, isFalse);
  });

  testWidgets(
    'account retirement during picker return never uploads late bytes',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _writablePage();
      final target = page.entries.firstWhere(
        (entry) => entry.kind == HomeResourceKind.resource,
      );
      final choice = Completer<CoreBoundedPickedFile?>();
      var requests = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          client: MockClient((_) async {
            requests++;
            return http.Response('', 500);
          }),
        ),
        CoreBoundedDownloadFileAccess(save: (_, _, _) async => null),
        () => harness.now,
        () => true,
        CoreBoundedUploadFileAccess(pick: () => choice.future),
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);

      final future = controller.chooseAndUpload(
        target,
        userRevision: page.userRevision,
        isCurrent: () => true,
      );
      await tester.pump();
      expect(controller.uploadPhase, CoreBoundedUploadPhase.choosingSource);
      await harness.account.signOut();
      choice.complete(
        CoreBoundedPickedFile(
          name: 'late.pdf',
          declaredLength: 1,
          chunks: Stream.value(Uint8List.fromList([1])),
        ),
      );
      await tester.runAsync(() => future);

      expect(requests, 0);
      expect(controller.uploadPhase, CoreBoundedUploadPhase.idle);
    },
  );

  testWidgets(
    'picker is single-flight and blocks download and history until handoff',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _writablePage();
      final target = page.entries.firstWhere(
        (entry) => entry.kind == HomeResourceKind.resource,
      );
      final bytes = Uint8List.fromList(utf8.encode('one picker result'));
      late Completer<CoreBoundedPickedFile?> choice;
      var picks = 0, requests = 0;
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          requestId: () => '8' * 32,
          client: MockClient((request) async {
            requests++;
            if (request.url.path.endsWith('/descriptor')) {
              return http.Response(
                '{"error":{"code":"not_found"}}',
                404,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({
                'blob': {
                  'requestId': '8' * 32,
                  'resourceId': target.id,
                  'serviceRevision': 1,
                  'contentLength': bytes.length,
                  'sha256': sha256.convert(bytes).toString(),
                  'contentType': 'application/pdf',
                  'createdAt': 10.0,
                  'updatedAt': 10.0,
                },
              }),
              201,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        CoreBoundedDownloadFileAccess(save: (_, _, _) async => null),
        () => harness.now,
        () => true,
        CoreBoundedUploadFileAccess(
          pick: () {
            picks++;
            return choice.future;
          },
        ),
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);

      await tester.runAsync(() async {
        choice = Completer<CoreBoundedPickedFile?>();
        final first = controller.chooseAndUpload(
          target,
          userRevision: page.userRevision,
          isCurrent: () => true,
        );
        await Future<void>.delayed(Duration.zero);
        await controller.chooseAndUpload(
          target,
          userRevision: page.userRevision,
          isCurrent: () => true,
        );
        await controller.download(
          target,
          userRevision: page.userRevision,
          isCurrent: () => true,
        );
        await controller.loadHistory(target, isCurrent: () => true);

        expect(controller.busy, isTrue);
        expect(controller.uploadPhase, CoreBoundedUploadPhase.choosingSource);
        expect((picks, requests), (1, 0));
        choice.complete(
          CoreBoundedPickedFile(
            name: 'single.pdf',
            declaredLength: bytes.length,
            chunks: Stream.value(bytes),
          ),
        );
        await first;
      });

      expect((picks, requests), (1, 2));
      expect(controller.uploadPhase, CoreBoundedUploadPhase.uploaded);
      expect(controller.busy, isFalse);
    },
  );

  testWidgets(
    'a new target operation retires evidence bound to the previous resource',
    (tester) async {
      final harness = ResourceHarness();
      await harness.mount(tester);
      await harness.signIn();
      await flush(tester);
      final page = _page(), first = page.entries.last;
      final raw = jsonDecode(
        jsonEncode((contract()['memberList'] as Map)['entries'][1]),
      ) as Map<String, dynamic>;
      (raw['ref'] as Map<String, dynamic>)['id'] = '4' * 32;
      raw['label'] = 'Second resource';
      final second = HomeResourceRecord.fromJson(
        raw,
        expectedContext: page.context,
      );
      final controller = CoreBoundedDownloadController(
        harness.home(tester),
        (endpoint) => CoreBoundedDownloadApi(
          endpoint: endpoint,
          requestId: () => 'c' * 32,
          client: MockClient((request) async => _verifiedResponse(request)),
        ),
        CoreBoundedDownloadFileAccess(
          save: (_, _, _) async => Uri.parse('content://synthetic/document'),
        ),
        () => harness.now,
        () => true,
      );
      addTearDown(controller.dispose);
      controller.setVisible(true);

      await tester.runAsync(
        () => controller.loadHistory(first, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
      expect(controller.historyTargetId, first.id);

      await tester.runAsync(
        () => controller.download(
          second,
          userRevision: page.userRevision,
          isCurrent: () => true,
        ),
      );
      expect(controller.phase, CoreBoundedDownloadPhase.saved);
      expect(controller.targetId, second.id);
      expect(controller.historyPhase, CoreBoundedHistoryPhase.idle);
      expect(controller.historyTargetId, isNull);
      expect(controller.history, isEmpty);

      await tester.runAsync(
        () => controller.loadHistory(first, isCurrent: () => true),
      );
      expect(controller.historyPhase, CoreBoundedHistoryPhase.ready);
      expect(controller.historyTargetId, first.id);
      expect(controller.phase, CoreBoundedDownloadPhase.idle);
      expect(controller.targetId, isNull);
      expect(controller.traceId, isNull);
    },
  );
}
