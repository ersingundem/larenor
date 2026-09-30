import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/media/bazarr/data/bazarr_client.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_config.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_subtitle_acquisition.dart';
import 'package:larenor/features/media/bazarr/data/models/bazarr_wanted_item.dart';
import 'package:larenor/features/media/bazarr/domain/bazarr_subtitle_request.dart';

final class _SocketHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final socket = await Socket.connect(request.url.host, request.url.port);
    final requestTarget = request.url.hasQuery
        ? '${request.url.path}?${request.url.query}'
        : request.url.path;
    socket.write('${request.method} $requestTarget HTTP/1.1\r\n');
    final headers = {
      ...request.headers,
      'host': request.url.authority,
      'connection': 'close',
      'content-length': '${body.length}',
    };
    for (final header in headers.entries) {
      socket.write('${header.key}: ${header.value}\r\n');
    }
    socket.write('\r\n');
    socket.add(body);
    await socket.flush();
    final raw = await socket.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    var split = -1;
    for (var index = 0; index <= raw.length - 4; index++) {
      if (raw[index] == 13 &&
          raw[index + 1] == 10 &&
          raw[index + 2] == 13 &&
          raw[index + 3] == 10) {
        split = index;
        break;
      }
    }
    if (split < 0) throw http.ClientException('fixture closed response');
    final lines = utf8.decode(raw.sublist(0, split)).split('\r\n');
    final responseHeaders = <String, String>{};
    for (final line in lines.skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        responseHeaders[line.substring(0, separator).toLowerCase()] = line
            .substring(separator + 1)
            .trim();
      }
    }
    return http.StreamedResponse(
      Stream.value(raw.sublist(split + 4)),
      int.parse(lines.first.split(' ')[1]),
      headers: responseHeaders,
      request: request,
    );
  }
}

final class _BazarrLoopback {
  _BazarrLoopback._(this.server, {required this.patchStatus});

  final HttpServer server;
  final int patchStatus;
  final List<_ObservedRequest> requests = [];

  static Future<_BazarrLoopback> start({int patchStatus = 204}) async {
    final fixture = _BazarrLoopback._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      patchStatus: patchStatus,
    );
    unawaited(fixture._serve());
    return fixture;
  }

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      final body = await utf8.decoder.bind(request).join();
      requests.add(
        _ObservedRequest(
          method: request.method,
          path: request.uri.path,
          query: request.uri.queryParameters,
          apiKey: request.headers.value('x-api-key'),
          contentType: request.headers.contentType?.mimeType,
          body: body,
        ),
      );
      if (request.method == 'PATCH' &&
          {
            '/api/movies/subtitles',
            '/api/episodes/subtitles',
          }.contains(request.uri.path)) {
        request.response.statusCode = patchStatus;
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/movies/wanted') {
        request.response.headers.contentType = ContentType.json;
        final response = utf8.encode(
          jsonEncode({
            'data': [
              {
                'radarrId': 41,
                'title': 'Arrival',
                'missing_subtitles': [
                  {'code2': 'de', 'name': 'German'},
                ],
              },
            ],
          }),
        );
        request.response.contentLength = response.length;
        request.response.add(response);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  }

  Future<void> close() => server.close(force: true);
}

final class _ObservedRequest {
  const _ObservedRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.apiKey,
    required this.contentType,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final String? apiKey;
  final String? contentType;
  final String body;
}

void main() {
  test('production Bazarr client acquires once and confirms through loopback readback', () async {
    final fixture = await _BazarrLoopback.start();
    addTearDown(fixture.close);
    final client = BazarrClient(
      config: BazarrConfig(baseUrl: fixture.baseUrl, apiKey: 'fixture-key'),
      httpClient: _SocketHttpClient(),
    );
    addTearDown(client.dispose);
    final wanted = BazarrWantedItem.fromJson({
      'radarrId': 41,
      'title': 'Arrival',
      'missing_subtitles': [
        {'code2': 'tr', 'name': 'Turkish'},
        {'code2': 'de', 'name': 'German'},
      ],
    });
    final request = BazarrSubtitleRequest.fromWanted(
      wanted,
      wanted.missingLanguages.first,
    );

    final result = await BazarrSubtitleAcquisition(client).acquire(request);

    expect(result.status, BazarrSubtitleAcquisitionStatus.confirmed);
    expect(fixture.requests, hasLength(2));
    final mutation = fixture.requests.first;
    expect(mutation.method, 'PATCH');
    expect(mutation.path, '/api/movies/subtitles');
    expect(mutation.apiKey, 'fixture-key');
    expect(mutation.contentType, 'application/x-www-form-urlencoded');
    expect(Uri.splitQueryString(mutation.body), {
      'radarrid': '41',
      'language': 'tr',
      'forced': 'false',
      'hi': 'false',
    });
    final readback = fixture.requests.last;
    expect(readback.method, 'GET');
    expect(readback.path, '/api/movies/wanted');
    expect(readback.query, {'start': '0', 'length': '50'});
    expect(readback.apiKey, 'fixture-key');
  });

  test(
    'uncertain Bazarr mutation is never retried or followed by readback',
    () async {
      final fixture = await _BazarrLoopback.start(
        patchStatus: HttpStatus.serviceUnavailable,
      );
      addTearDown(fixture.close);
      final client = BazarrClient(
        config: BazarrConfig(baseUrl: fixture.baseUrl, apiKey: 'fixture-key'),
        httpClient: _SocketHttpClient(),
      );
      addTearDown(client.dispose);
      final wanted = BazarrWantedItem.fromJson({
        'sonarrSeriesId': 7,
        'sonarrEpisodeId': 12,
        'title': 'Pilot',
        'missing_subtitles': [
          {'code2': 'tr'},
        ],
      });
      final request = BazarrSubtitleRequest.fromWanted(
        wanted,
        wanted.missingLanguages.single,
      );

      final result = await BazarrSubtitleAcquisition(client).acquire(request);

      expect(result.status, BazarrSubtitleAcquisitionStatus.uncertain);
      expect(fixture.requests, hasLength(1));
      expect(fixture.requests.single.method, 'PATCH');
      expect(fixture.requests.single.path, '/api/episodes/subtitles');
    },
  );
}
