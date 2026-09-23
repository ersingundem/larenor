import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/media/language_preferences/data/core_media_language_preferences_api.dart';
import 'package:larenor/features/media/language_preferences/domain/core_media_language_preferences.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const account = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';
const requestId = '55555555555555555555555555555555';
const token = 'synthetic-access-token-never-in-url-or-body';

final class SocketHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final socket = await Socket.connect(request.url.host, request.url.port);
    socket.write('${request.method} ${request.url.path} HTTP/1.1\r\n');
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
    if (split < 0) throw const FormatException('invalid HTTP response');
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

Map<String, Object?> response({
  int revision = 0,
  String? audio,
  String? subtitle,
  String accountId = account,
}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
    'accountId': accountId,
    'sessionFamilyId': family,
    'accountRevision': 3,
    'preferenceRevision': revision,
  },
  'preference': revision == 0
      ? null
      : {
          'schemaVersion': 1,
          'ref': {
            'schemaVersion': 1,
            'coreId': core,
            'homeId': home,
            'accountId': accountId,
            'kind': 'media_language_preferences',
          },
          'revision': revision,
          'audioLanguage': audio,
          'subtitleLanguage': subtitle,
        },
};

final class LanguageCoreFixture {
  LanguageCoreFixture._(this.server);
  final HttpServer server;
  final requests = <Map<String, Object?>>[];
  Map<String, Object?> current = response();

  static Future<LanguageCoreFixture> start() async {
    final fixture = LanguageCoreFixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    unawaited(fixture._serve());
    return fixture;
  }

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      final text = await utf8.decoder.bind(request).join();
      final body = text.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(text) as Map);
      requests.add({
        'method': request.method,
        'path': request.uri.path,
        'query': request.uri.query,
        'body': body,
      });
      if (request.method == 'PUT') {
        current = response(
          revision: 1,
          audio: body['audioLanguage'] as String?,
          subtitle: body['subtitleLanguage'] as String?,
        );
      }
      final encoded = utf8.encode(jsonEncode(current));
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': core,
    'homeId': home,
  });

  test(
    'real loopback wire uses exact Core CAS contract without secret fields',
    () async {
      final fixture = await LanguageCoreFixture.start();
      addTearDown(fixture.close);
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint(fixture.baseUrl),
        client: SocketHttpClient(),
      );
      addTearDown(transport.close);
      final api = CoreMediaLanguagePreferencesApi(
        transport,
        token,
        context,
        account,
      );

      final empty = await api.read();
      final saved = await api.save(
        base: empty,
        requestId: requestId,
        audioLanguage: 'tr-tr',
        subtitleLanguage: 'off',
      );

      expect(saved.preference?.audioLanguage, 'tr-tr');
      expect(saved.preference?.subtitleLanguage, 'off');
      expect(saved.authority.preferenceRevision, 1);
      expect(fixture.requests.map((value) => value['method']), ['GET', 'PUT']);
      final put = fixture.requests.last;
      expect(put['path'], '/api/v1/media/language-preferences/$core/$home');
      expect(put['query'], isEmpty);
      expect(put['body'], {
        'schemaVersion': 1,
        'requestId': requestId,
        'expectedAccountRevision': 3,
        'expectedRevision': 0,
        'audioLanguage': 'tr-tr',
        'subtitleLanguage': 'off',
      });
      expect(jsonEncode(put), isNot(contains(token)));
    },
  );

  test('foreign authority and non-integer revisions fail closed', () {
    for (final raw in [
      response(revision: 1, audio: 'en', accountId: 'f' * 32),
      {
        ...response(revision: 1, audio: 'en'),
        'authority': {
          ...(response(revision: 1, audio: 'en')['authority']! as Map),
          'preferenceRevision': 1.0,
        },
      },
    ]) {
      expect(
        () => CoreMediaLanguageSnapshot.fromJson(
          raw,
          context: context,
          accountId: account,
        ),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });
}
