import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_controller.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_file_access.dart';
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

http.Response _response({bool validDigest = true}) {
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
      'x-larenor-service-revision': '1',
      'accept-ranges': 'none',
    },
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

HomeResourcePage _page() {
  final raw = contract();
  return HomeResourcePage.fromJson(
    raw['memberList'],
    expectedContext: ServerContext.fromJson(raw['context']),
  );
}

void main() {
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
          client: MockClient((request) async {
            requests++;
            expect(request.method, 'POST');
            return _response();
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
      expect(controller.traceId, 'c' * 32);
      expect(utf8.decode(published!), 'verified fixture');
      expect((requests, saves), (1, 1));
      await tester.runAsync(
        () => controller.download(
          page.entries.first,
          userRevision: page.userRevision,
          isCurrent: () => true,
        ),
      );
      expect(
        requests,
        1,
        reason: 'a room is never a binary download authority',
      );
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
        client: MockClient((_) async {
          requests++;
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
    expect((requests, saves), (1, 0));
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
        client: MockClient((_) async {
          requests++;
          return _response();
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
    expect((requests, saves), (1, 1));
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
        (endpoint) =>
            CoreBoundedDownloadApi(endpoint: endpoint, client: pending),
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
        (endpoint) =>
            CoreBoundedDownloadApi(endpoint: endpoint, client: pending),
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
        (endpoint) =>
            CoreBoundedDownloadApi(endpoint: endpoint, client: pending),
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
}
