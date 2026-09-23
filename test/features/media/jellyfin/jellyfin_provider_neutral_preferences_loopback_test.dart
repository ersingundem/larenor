import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_controller.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const account = '33333333333333333333333333333333';
const family = '44444444444444444444444444444444';

final class SocketHttpClient extends http.BaseClient {
  bool failFirstLanguagePut = true;

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
    if (failFirstLanguagePut &&
        request.method == 'PUT' &&
        request.url.path.contains('/media/language-preferences/')) {
      failFirstLanguagePut = false;
      throw http.ClientException('fixture lost committed response');
    }
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

final class MemorySessions implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class LanguagePreferenceCore {
  LanguagePreferenceCore._(this.server);
  final HttpServer server;
  final puts = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, Object?>>{};
  int revision = 0;
  String? audio;
  String? subtitle;

  static Future<LanguagePreferenceCore> start() async {
    final value = LanguagePreferenceCore._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    unawaited(value._serve());
    return value;
  }

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Map<String, Object?> get snapshot => {
    'schemaVersion': 1,
    'authority': {
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
      'accountId': account,
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
              'accountId': account,
              'kind': 'media_language_preferences',
            },
            'revision': revision,
            'audioLanguage': audio,
            'subtitleLanguage': subtitle,
          },
  };

  Future<void> _serve() async {
    await for (final request in server) {
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(bodyText) as Map);
      Object result;
      if (request.uri.path.endsWith('/auth/login')) {
        result = {
          'accessToken': 'a' * 43,
          'refreshToken': 'b' * 43,
          'expiresIn': 3600,
          'sessionFamilyId': family,
          'user': {
            'id': account,
            'username': 'listener',
            'role': 'member',
            'mustChangePassword': false,
          },
        };
      } else if (request.uri.path.endsWith('/context')) {
        result = {'schemaVersion': 1, 'coreId': core, 'homeId': home};
      } else if (request.uri.path.contains('/media/language-preferences/')) {
        if (request.method == 'GET') {
          result = snapshot;
        } else {
          puts.add(body);
          final requestId = body['requestId'] as String;
          final replay = receipts[requestId];
          if (replay == null) {
            revision++;
            audio = body['audioLanguage'] as String?;
            subtitle = body['subtitleLanguage'] as String?;
            receipts[requestId] = snapshot;
          }
          result = receipts[requestId]!;
        }
      } else {
        request.response.statusCode = 404;
        result = {
          'error': {'code': 'not_found'},
        };
      }
      final encoded = utf8.encode(jsonEncode(result));
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    }
  }

  Future<void> close() => server.close(force: true);
}

String _legacyKey(JellyfinConfig config) {
  final scope = sha256.convert(
    utf8.encode('${config.baseUrl}\u0000${config.userId}'),
  );
  return 'jellyfin_track_languages_v1_$scope';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'uncertain Core PUT retries the exact request once over real loopback',
    () async {
      final coreHost = await LanguagePreferenceCore.start();
      addTearDown(coreHost.close);
      final sessions = MemorySessions();
      final accountController = ServerAccountController(
        store: sessions,
        apiFactory: (endpoint) =>
            LarenorServerApi(endpoint: endpoint, client: SocketHttpClient()),
      );
      addTearDown(accountController.dispose);
      await accountController.signIn(
        baseUrl: coreHost.baseUrl,
        username: 'listener',
        password: 'synthetic password',
        deviceName: 'tablet',
      );
      expect(accountController.session, isNotNull);
      final store = JellyfinTrackPreferencesStore(account: accountController);
      const direct = JellyfinConfig(
        baseUrl: 'https://direct-jellyfin.invalid',
        userId: 'direct-user',
        accessToken: 'must-never-cross-core-wire',
        deviceId: 'tablet',
      );

      final saved = await store.saveAudio(
        direct,
        language: 'tr-TR',
        isCurrent: () => true,
      );

      expect(saved.audioLanguage, 'tr-tr');
      expect(coreHost.revision, 1);
      expect(coreHost.puts, hasLength(2));
      expect(coreHost.puts.first, coreHost.puts.last);
      expect(
        coreHost.puts.first['requestId'],
        matches(RegExp(r'^[0-9a-f]{32}$')),
      );
      expect(jsonEncode(coreHost.puts), isNot(contains(direct.accessToken)));
      expect(jsonEncode(coreHost.puts), isNot(contains(direct.baseUrl)));
      expect(jsonEncode(coreHost.puts), isNot(contains(direct.userId)));
    },
  );

  test(
    'confirmed legacy preview crosses real Core wire and retires on logout replacement',
    () async {
      final coreHost = await LanguagePreferenceCore.start();
      addTearDown(coreHost.close);
      final sessions = MemorySessions();
      final accountController = ServerAccountController(
        store: sessions,
        apiFactory: (endpoint) =>
            LarenorServerApi(endpoint: endpoint, client: SocketHttpClient()),
      );
      addTearDown(accountController.dispose);
      await accountController.signIn(
        baseUrl: coreHost.baseUrl,
        username: 'listener',
        password: 'synthetic password',
        deviceName: 'tablet',
      );
      const direct = JellyfinConfig(
        baseUrl: 'https://direct-jellyfin.invalid',
        userId: 'direct-user',
        accessToken: 'must-never-cross-core-wire',
        deviceId: 'tablet',
      );
      final raw = jsonEncode({
        'version': 1,
        'audio': 'tur',
        'subtitle': 'off',
      });
      SharedPreferences.setMockInitialValues({_legacyKey(direct): raw});
      final session = accountController.session;
      final controller = LegacyJellyfinTrackPreferencesMigrationController(
        migration: LegacyJellyfinTrackPreferencesMigration(
          core: JellyfinTrackPreferencesStore(account: accountController),
        ),
        config: direct,
        isCurrent: () => identical(accountController.session, session),
        lifecycle: accountController,
      );
      addTearDown(controller.dispose);

      await controller.start();
      expect(
        controller.state.phase,
        LegacyJellyfinTrackPreferencesMigrationPhase.ready,
      );
      await controller.confirm();

      expect(
        controller.state.phase,
        LegacyJellyfinTrackPreferencesMigrationPhase.applied,
      );
      expect(coreHost.revision, 1);
      expect(coreHost.audio, 'tr');
      expect(coreHost.subtitle, 'off');
      expect(
        (await SharedPreferences.getInstance()).containsKey(_legacyKey(direct)),
        isFalse,
      );
      final wire = jsonEncode(coreHost.puts);
      expect(wire, isNot(contains(direct.baseUrl)));
      expect(wire, isNot(contains(direct.userId)));
      expect(wire, isNot(contains(direct.accessToken)));
      expect(wire, isNot(contains(raw)));

      SharedPreferences.setMockInitialValues({_legacyKey(direct): raw});
      final replacementSource = accountController.session;
      final retiring = LegacyJellyfinTrackPreferencesMigrationController(
        migration: LegacyJellyfinTrackPreferencesMigration(
          core: JellyfinTrackPreferencesStore(account: accountController),
        ),
        config: direct,
        isCurrent: () =>
            identical(accountController.session, replacementSource),
        lifecycle: accountController,
      );
      addTearDown(retiring.dispose);
      await retiring.start();
      expect(
        retiring.state.phase,
        LegacyJellyfinTrackPreferencesMigrationPhase.ready,
      );
      await accountController.signOut();
      expect(
        retiring.state.phase,
        LegacyJellyfinTrackPreferencesMigrationPhase.retired,
      );
      await accountController.signIn(
        baseUrl: coreHost.baseUrl,
        username: 'listener',
        password: 'replacement password',
        deviceName: 'replacement tablet',
      );
      await retiring.confirm();

      expect(
        retiring.state.phase,
        LegacyJellyfinTrackPreferencesMigrationPhase.retired,
      );
      expect(coreHost.revision, 1);
      expect(
        (await SharedPreferences.getInstance()).getString(_legacyKey(direct)),
        raw,
      );
    },
  );
}
