import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/web_panel/data/web_panel_transfers.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const upload = FileSelectorParams(
  isCaptureEnabled: false,
  acceptTypes: ['application/pdf'],
  mode: FileSelectorMode.open,
);

final validPdf = Uint8List.fromList(
  '%PDF-1.7\n'
          '1 0 obj\n<< /Type /Catalog >>\nendobj\n'
          'xref\n0 1\n0000000000 65535 f \n'
          'trailer\n<< /Root 1 0 R >>\n'
          'startxref\n42\n%%EOF\n'
      .codeUnits,
);

final validJpeg = Uint8List.fromList(const [
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
  0xff,
  0xda,
  0x00,
  0x08,
  0x01,
  0x01,
  0x00,
  0x00,
  0x3f,
  0x00,
  0x01,
  0xff,
  0xd9,
]);

final malformedJpeg = Uint8List.fromList(const [
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x08,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0xff,
  0xda,
  0x00,
  0x06,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0xff,
  0xd9,
]);

Uint8List zeroHeightJpeg() {
  final bytes = Uint8List.fromList(validJpeg);
  bytes[7] = 0;
  bytes[8] = 0;
  return bytes;
}

final validPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

final oversizedPngHeader = base64Decode(
  'iVBORw0KGgoAAAANSUhEUv////8AAAABCAIAAACPPoGdAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC',
);

final invalidPngColorDepth = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAwQAAADCzD0TAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC',
);

final validWebp = base64Decode(
  'UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA',
);

Uint8List duplicateWebpImageChunk() {
  final chunks = validWebp.sublist(12);
  final bytes = Uint8List.fromList([
    ...validWebp.sublist(0, 12),
    ...chunks,
    ...chunks,
  ]);
  final riffLength = bytes.length - 8;
  for (var offset = 0; offset < 4; offset++) {
    bytes[4 + offset] = (riffLength >> (offset * 8)) & 0xff;
  }
  return bytes;
}

List<int> webpChunk(String type, List<int> payload) => [
  ...type.codeUnits,
  payload.length & 0xff,
  (payload.length >> 8) & 0xff,
  (payload.length >> 16) & 0xff,
  (payload.length >> 24) & 0xff,
  ...payload,
  if (payload.length.isOdd) 0,
];

Uint8List webpContainer(List<List<int>> chunks) {
  final payload = chunks.expand((chunk) => chunk).toList(growable: false);
  final riffLength = payload.length + 4;
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    riffLength & 0xff,
    (riffLength >> 8) & 0xff,
    (riffLength >> 16) & 0xff,
    (riffLength >> 24) & 0xff,
    ...'WEBP'.codeUnits,
    ...payload,
  ]);
}

List<int> get validVp8Chunk => validWebp.sublist(12);
final validVp8lChunk = webpChunk('VP8L', const [0x2f, 0, 0, 0, 0]);

Uint8List malformedAnimatedWebp(
  List<List<int>> frameChunks, {
  bool duplicateAnim = false,
}) {
  final frame = webpChunk('ANMF', [
    ...List<int>.filled(16, 0),
    ...frameChunks.expand((chunk) => chunk),
  ]);
  return webpContainer([
    webpChunk('VP8X', [0x02, ...List<int>.filled(9, 0)]),
    webpChunk('ANIM', List<int>.filled(6, 0)),
    if (duplicateAnim) webpChunk('ANIM', List<int>.filled(6, 0)),
    frame,
  ]);
}

final animationHeaderOnlyWebp = Uint8List.fromList(const [
  0x52,
  0x49,
  0x46,
  0x46,
  0x1c,
  0x00,
  0x00,
  0x00,
  0x57,
  0x45,
  0x42,
  0x50,
  0x41,
  0x4e,
  0x4d,
  0x46,
  0x10,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
]);

final class Access implements WebPanelTransferAccess {
  final uploadGate = Completer<List<String>>();
  final downloadGate = Completer<bool>();
  int uploads = 0, downloads = 0;
  Uri? downloaded;

  @override
  Future<List<String>> pickUpload(FileSelectorParams request) {
    uploads++;
    return uploadGate.future;
  }

  @override
  Future<bool> download(
    Uri uri,
    WebPanelPolicy policy,
    bool Function() isCurrent,
  ) {
    downloads++;
    downloaded = uri;
    return downloadGate.future;
  }
}

final class ThrowingAccess implements WebPanelTransferAccess {
  @override
  Future<List<String>> pickUpload(FileSelectorParams request) async =>
      throw StateError('picker unavailable');

  @override
  Future<bool> download(
    Uri uri,
    WebPanelPolicy policy,
    bool Function() isCurrent,
  ) async => throw StateError('transport unavailable');
}

base class FixturePlatformFile extends PlatformFile {
  FixturePlatformFile(this.uri, this.size);

  @override
  final Uri uri;
  final int? size;

  @override
  String get name => 'fixture.pdf';

  @override
  Never get xFile => throw UnsupportedError('fixture has no platform file');

  @override
  int? lengthSync() => size;

  @override
  Future<int?> length() async => size;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}

void main() {
  test(
    'upload exposes only unique bounded content grants with one aggregate cap',
    () async {
      Future<List<String>> pick(List<PlatformFile> files) =>
          LocalWebPanelTransferAccess(
            pickFiles: ({required allowMultiple, required allowedExtensions}) {
              return Future.value(files);
            },
          ).pickUpload(
            const FileSelectorParams(
              isCaptureEnabled: false,
              acceptTypes: ['application/pdf'],
              mode: FileSelectorMode.openMultiple,
            ),
          );

      expect(
        await pick([
          FixturePlatformFile(Uri.parse('file:///private/secret.pdf'), 1),
        ]),
        isEmpty,
      );
      expect(
        await pick([
          FixturePlatformFile(Uri.parse('content://fixture/document/1'), 1),
          FixturePlatformFile(Uri.parse('content://fixture/document/1'), 1),
        ]),
        isEmpty,
      );
      expect(
        await pick([
          FixturePlatformFile(
            Uri.parse('content://fixture/document/1'),
            webPanelMaxTransferBytes,
          ),
          FixturePlatformFile(Uri.parse('content://fixture/document/2'), 1),
        ]),
        isEmpty,
      );
      expect(
        await pick([
          FixturePlatformFile(Uri.parse('content://fixture/document/1'), 3),
          FixturePlatformFile(Uri.parse('content://fixture/document/2'), 4),
        ]),
        const ['content://fixture/document/1', 'content://fixture/document/2'],
      );
    },
  );

  test('download total deadline suppresses a late streamed payload', () async {
    final stream = StreamController<List<int>>();
    var exports = 0;
    final access = LocalWebPanelTransferAccess(
      transferTimeout: const Duration(milliseconds: 10),
      client: () => MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          stream.stream,
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      ),
      saveFile: (_, _, _) async {
        exports++;
        return Uri.parse('content://fixture/unexpected');
      },
    );

    expect(
      await access.download(
        Uri.parse('https://panel.invalid/file'),
        WebPanelPolicy.fromUrl('https://panel.invalid')!,
        () => true,
      ),
      false,
    );
    stream.add(validPdf);
    await stream.close();
    await pumpEventQueue();
    expect(exports, 0);
  });

  test('download rechecks authority after the platform save returns', () async {
    final saveGate = Completer<Uri?>();
    var current = true;
    final access = LocalWebPanelTransferAccess(
      client: () => MockClient(
        (_) async => http.Response.bytes(
          validPdf,
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      ),
      saveFile: (_, _, _) => saveGate.future,
    );

    final pending = access.download(
      Uri.parse('https://panel.invalid/file'),
      WebPanelPolicy.fromUrl('https://panel.invalid')!,
      () => current,
    );
    await pumpEventQueue();
    current = false;
    saveGate.complete(Uri.parse('content://fixture/saved'));
    expect(await pending, false);
  });

  test(
    'picker failure retires working state and allows explicit retry',
    () async {
      final controller = WebPanelTransferController(
        policy: WebPanelPolicy.fromUrl('https://panel.invalid')!,
        access: ThrowingAccess(),
        uploadsEnabled: true,
        downloadsEnabled: false,
        isCurrent: () => true,
      );
      controller.armUpload();
      expect(await controller.selectUpload(upload), isEmpty);
      expect(controller.status, WebPanelTransferStatus.failed);
      controller.armUpload();
      expect(controller.status, WebPanelTransferStatus.uploadArmed);
      controller.dispose();
    },
  );

  test(
    'transport failure retires working state without download replay',
    () async {
      final controller = WebPanelTransferController(
        policy: WebPanelPolicy.fromUrl('https://panel.invalid')!,
        access: ThrowingAccess(),
        uploadsEnabled: false,
        downloadsEnabled: true,
        isCurrent: () => true,
      );
      controller.armDownload();
      expect(
        controller.captureDownload('https://panel.invalid/file.pdf'),
        true,
      );
      await pumpEventQueue();
      expect(controller.status, WebPanelTransferStatus.failed);
      expect(
        controller.captureDownload('https://panel.invalid/file.pdf'),
        false,
      );
      controller.dispose();
    },
  );

  test(
    'upload requires a fresh one-shot grant and rejects late completion',
    () async {
      var current = true;
      final access = Access();
      final controller = WebPanelTransferController(
        policy: WebPanelPolicy.fromUrl('https://panel.invalid')!,
        access: access,
        uploadsEnabled: true,
        downloadsEnabled: false,
        isCurrent: () => current,
      );
      expect(await controller.selectUpload(upload), isEmpty);
      controller.armUpload();
      expect(controller.status, WebPanelTransferStatus.uploadArmed);
      final pending = controller.selectUpload(upload);
      expect(controller.status, WebPanelTransferStatus.working);
      current = false;
      access.uploadGate.complete(['content://fixture/document/1']);
      expect(await pending, isEmpty);
      expect(access.uploads, 1);
      expect(await controller.selectUpload(upload), isEmpty);
      controller.dispose();
    },
  );

  test(
    'download consumes one exact-origin navigation and never replays',
    () async {
      final access = Access();
      final controller = WebPanelTransferController(
        policy: WebPanelPolicy.fromUrl('https://panel.invalid/start')!,
        access: access,
        uploadsEnabled: false,
        downloadsEnabled: true,
        isCurrent: () => true,
      );
      controller.armDownload();
      expect(controller.captureDownload('https://evil.invalid/file.pdf'), true);
      expect(controller.status, WebPanelTransferStatus.denied);
      expect(access.downloads, 0);

      controller.armDownload();
      expect(
        controller.captureDownload('https://panel.invalid/file.pdf?private=x'),
        true,
      );
      expect(access.downloads, 1);
      expect(access.downloaded?.host, 'panel.invalid');
      expect(
        controller.captureDownload('https://panel.invalid/file.pdf'),
        false,
      );
      access.downloadGate.complete(true);
      await pumpEventQueue();
      expect(controller.status, WebPanelTransferStatus.completed);
      controller.dispose();
    },
  );

  test(
    'anonymous downloader bounds redirects mime size and exported bytes',
    () async {
      final requests = <http.Request>[];
      Uint8List? saved;
      final access = LocalWebPanelTransferAccess(
        client: () => MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/start') {
            return http.Response('', 302, headers: {'location': '/file.pdf'});
          }
          return http.Response.bytes(
            validPdf,
            200,
            headers: {'content-type': 'application/pdf'},
          );
        }),
        saveFile: (name, mime, bytes) async {
          expect(name, 'web-panel-download.pdf');
          expect(mime, 'application/pdf');
          saved = bytes;
          return Uri.parse('content://fixture/saved');
        },
      );
      final policy = WebPanelPolicy.fromUrl('https://panel.invalid')!;
      expect(
        await access.download(
          Uri.parse('https://panel.invalid/start?private=x'),
          policy,
          () => true,
        ),
        true,
      );
      expect(saved, validPdf);
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.headers.containsKey('authorization'), false);
        expect(request.headers.containsKey('cookie'), false);
        expect(request.followRedirects, false);
      }

      final crossOrigin = LocalWebPanelTransferAccess(
        client: () => MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'https://evil.invalid/file.pdf'},
          ),
        ),
        saveFile: (_, _, _) async => Uri.parse('content://fixture/unexpected'),
      );
      expect(
        await crossOrigin.download(
          Uri.parse('https://panel.invalid/start'),
          policy,
          () => true,
        ),
        false,
      );

      var exports = 0;
      for (final client in [
        () => MockClient(
          (_) async => http.Response(
            'script',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
        () => MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value([1]),
            200,
            contentLength: webPanelMaxTransferBytes + 1,
            headers: {'content-type': 'application/pdf'},
          ),
        ),
      ]) {
        final bounded = LocalWebPanelTransferAccess(
          client: client,
          saveFile: (_, _, _) async {
            exports++;
            return Uri.parse('content://fixture/unexpected');
          },
        );
        expect(
          await bounded.download(
            Uri.parse('https://panel.invalid/file'),
            policy,
            () => true,
          ),
          false,
        );
      }
      expect(exports, 0);
    },
  );

  test('declared safe mime must match bounded payload before SAF', () async {
    var exports = 0;
    for (final fixture in <(String, List<int>)>[
      ('application/pdf', '<html>not a pdf</html>'.codeUnits),
      ('application/pdf', '%PDF-1.7<html>polyglot</html>'.codeUnits),
      ('image/jpeg', [0x89, 0x50, 0x4e, 0x47]),
      ('image/jpeg', [0xff, 0xd8, 0xff, 0xe0]),
      ('image/jpeg', malformedJpeg),
      ('image/jpeg', zeroHeightJpeg()),
      ('image/png', [0xff, 0xd8, 0xff, 0xe0]),
      ('image/png', [...validPng]..removeLast()),
      ('image/png', oversizedPngHeader),
      ('image/png', invalidPngColorDepth),
      ('image/webp', 'RIFF0000NOPE'.codeUnits),
      ('image/webp', 'RIFF0000WEBP'.codeUnits),
      ('image/webp', animationHeaderOnlyWebp),
      ('image/webp', duplicateWebpImageChunk()),
      (
        'image/webp',
        malformedAnimatedWebp([validVp8Chunk], duplicateAnim: true),
      ),
      (
        'image/webp',
        malformedAnimatedWebp([
          validVp8Chunk,
          webpChunk('ALPH', const [0]),
        ]),
      ),
      (
        'image/webp',
        malformedAnimatedWebp([
          webpChunk('ALPH', const [0]),
          webpChunk('ALPH', const [0]),
          validVp8Chunk,
        ]),
      ),
      (
        'image/webp',
        malformedAnimatedWebp([
          webpChunk('ALPH', const [0]),
          validVp8lChunk,
        ]),
      ),
      ('text/plain', [0x66, 0x6f, 0x00, 0x6f]),
      ('text/csv', [0xc3, 0x28]),
      ('application/json', '{"unfinished":'.codeUnits),
      ('application/octet-stream', [1, 2, 3]),
    ]) {
      final access = LocalWebPanelTransferAccess(
        client: () => MockClient(
          (_) async => http.Response.bytes(
            fixture.$2,
            200,
            headers: {'content-type': fixture.$1},
          ),
        ),
        saveFile: (_, _, _) async {
          exports++;
          return Uri.parse('content://fixture/unexpected');
        },
      );
      expect(
        await access.download(
          Uri.parse('https://panel.invalid/file'),
          WebPanelPolicy.fromUrl('https://panel.invalid')!,
          () => true,
        ),
        false,
        reason: fixture.$1,
      );
    }
    expect(exports, 0);
  });

  test('structurally framed binary payloads reach SAF unchanged', () async {
    for (final fixture in <(String, Uint8List)>[
      ('application/pdf', validPdf),
      ('image/jpeg', validJpeg),
      ('image/png', validPng),
      ('image/webp', validWebp),
    ]) {
      Uint8List? saved;
      final access = LocalWebPanelTransferAccess(
        client: () => MockClient(
          (_) async => http.Response.bytes(
            fixture.$2,
            200,
            headers: {'content-type': fixture.$1},
          ),
        ),
        saveFile: (_, _, bytes) async {
          saved = bytes;
          return Uri.parse('content://fixture/saved');
        },
      );
      expect(
        await access.download(
          Uri.parse('https://panel.invalid/file'),
          WebPanelPolicy.fromUrl('https://panel.invalid')!,
          () => true,
        ),
        true,
        reason: fixture.$1,
      );
      expect(saved, fixture.$2);
    }
  });
}
