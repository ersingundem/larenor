import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_resources/data/core_bounded_download_api.dart';
import 'package:larenor/features/home_resources/data/core_bounded_download_file_access.dart';
import 'package:larenor/features/home_resources/data/core_bounded_media_preflight.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resources_fixture.dart';

HomeResourceRecord _target() {
  final fixture = contract();
  return HomeResourcePage.fromJson(
    fixture['memberList'],
    expectedContext: ServerContext.fromJson(fixture['context']),
  ).entries.last;
}

Uint8List _frame(String trace, int sequence, bool finalFrame, List<int> bytes) {
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('LRB1'))
    ..add(ascii.encode(trace));
  final fields = ByteData(13)
    ..setUint64(0, sequence)
    ..setUint8(8, finalFrame ? 1 : 0)
    ..setUint32(9, bytes.length);
  output
    ..add(fields.buffer.asUint8List())
    ..add(bytes);
  return output.takeBytes();
}

Future<CoreBoundedBlob> _download(String contentType, List<int> payload) async {
  final trace = 'd' * 32;
  final wire = Uint8List.fromList([
    ..._frame(trace, 0, false, payload),
    ..._frame(trace, 1, true, const []),
  ]);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await request.drain<void>();
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType(
        'application',
        'vnd.larenor.blob-stream.v1',
      )
      ..headers.set('x-larenor-trace-id', trace)
      ..headers.set('x-larenor-blob-content-length', payload.length)
      ..headers.set('x-larenor-blob-sha256', sha256.convert(payload).toString())
      ..headers.set('x-larenor-blob-content-type', contentType)
      ..headers.set('x-larenor-service-revision', 1)
      ..headers.set('x-larenor-resume-offset', 0)
      ..headers.set('accept-ranges', 'none')
      ..contentLength = wire.length
      ..add(wire);
    await request.response.close();
  });
  final api = CoreBoundedDownloadApi(
    endpoint: ServerEndpoint('http://127.0.0.1:${server.port}'),
    client: http.Client(),
    requestId: () => trace,
  );
  try {
    return await api.download(
      token: 'synthetic-token',
      target: _target(),
      expectedUserRevision: 7,
      expectedServiceRevision: 1,
    );
  } finally {
    api.close();
    await server.close(force: true);
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('accepts bounded document image audio and video signatures', () {
    final cases = <String, List<int>>{
      'text/plain; charset=utf-8': utf8.encode('Larenor Türkçe'),
      'application/json': utf8.encode('{"safe":true}'),
      'application/pdf': ascii.encode('%PDF-1.7\n%%EOF'),
      'image/png': [137, 80, 78, 71, 13, 10, 26, 10, 0],
      'image/jpeg': [255, 216, 255, 224, 0, 255, 217],
      'image/webp': ascii.encode('RIFF0000WEBPVP8 '),
      'audio/mpeg': [...ascii.encode('ID3'), 4, 0, 0, 0],
      'audio/flac': ascii.encode('fLaC0000'),
      'audio/wav': ascii.encode('RIFF0000WAVEfmt '),
      'audio/ogg': ascii.encode('OggS0000'),
      'video/mp4': [0, 0, 0, 16, ...ascii.encode('ftypisom'), 0, 0, 0, 0],
      'video/webm': [0x1a, 0x45, 0xdf, 0xa3, 0x01],
    };

    for (final entry in cases.entries) {
      expect(
        () => CoreBoundedMediaPreflight.verify(entry.key, entry.value),
        returnsNormally,
        reason: entry.key,
      );
    }
  });

  test('rejects active, unknown, parameter-smuggled and malformed text', () {
    final cases = <String, List<int>>{
      'text/html': utf8.encode('<script>alert(1)</script>'),
      'image/svg+xml': utf8.encode('<svg/>'),
      'application/javascript': utf8.encode('alert(1)'),
      'application/octet-stream': [1, 2, 3],
      'text/plain; charset=utf-8; name=page.html': utf8.encode('safe'),
      'text/plain; charset=iso-8859-9': [0xff],
      'text/plain': [0xc3, 0x28],
      'application/json': utf8.encode('{"broken":'),
    };

    for (final entry in cases.entries) {
      expect(
        () => CoreBoundedMediaPreflight.verify(entry.key, entry.value),
        throwsA(
          isA<CoreBoundedDownloadException>().having(
            (error) => error.code,
            'code',
            'file_access_failed',
          ),
        ),
        reason: entry.key,
      );
    }
  });

  test('rejects declared media with mismatched magic before SAF', () async {
    for (final contentType in [
      'application/pdf',
      'image/png',
      'image/jpeg',
      'image/webp',
      'audio/mpeg',
      'audio/flac',
      'audio/wav',
      'audio/ogg',
      'video/mp4',
      'video/webm',
    ]) {
      final blob = await _download(contentType, utf8.encode('wrong signature'));
      var saves = 0;
      final access = CoreBoundedDownloadFileAccess(
        save: (_, _, _) async {
          saves++;
          return Uri.parse('content://must-not-run');
        },
      );

      await expectLater(
        access.publish(blob, _target().id),
        throwsA(
          isA<CoreBoundedDownloadException>().having(
            (error) => error.code,
            'code',
            'file_access_failed',
          ),
        ),
        reason: contentType,
      );
      expect(saves, 0, reason: contentType);
    }
  });
}
