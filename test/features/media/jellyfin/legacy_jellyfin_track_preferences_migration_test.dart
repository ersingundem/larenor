import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../server/server_admin_test_support.dart';

const _config = JellyfinConfig(
  baseUrl: 'https://private-jellyfin.invalid/root',
  userId: 'private-user-id',
  accessToken: 'private-access-token',
  deviceId: 'private-device-id',
);

String _legacyKey(JellyfinConfig config) {
  final scope = sha256.convert(
    utf8.encode('${config.baseUrl}\u0000${config.userId}'),
  );
  return 'jellyfin_track_languages_v1_$scope';
}

Map<String, dynamic> _response(
  AdminFixture fixture, {
  required int revision,
  required String? audio,
  required String? subtitle,
}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'accountId': fixture.user.id,
    'accountRevision': 1,
    'sessionFamilyId': sessionFamilyId,
    'preferenceRevision': revision,
  },
  'preference': revision == 0
      ? null
      : {
          'schemaVersion': 1,
          'ref': {
            'schemaVersion': 1,
            'coreId': 'a' * 32,
            'homeId': 'b' * 32,
            'accountId': fixture.user.id,
            'kind': 'media_language_preferences',
          },
          'revision': revision,
          'audioLanguage': audio,
          'subtitleLanguage': subtitle,
        },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('confirmed preview fresh-merges Core siblings then retires exact legacy record', () async {
    final raw = jsonEncode({'version': 1, 'audio': 'tur', 'subtitle': null});
    SharedPreferences.setMockInitialValues({_legacyKey(_config): raw});
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    var revision = 7;
    String? audio = 'en';
    String? subtitle = 'de';
    fixture.respond = (request) async {
      if (!request.url.path.contains('/media/language-preferences/')) {
        return fixture.defaultResponse(request);
      }
      if (request.method == 'GET') {
        return fixture.json(
          _response(
            fixture,
            revision: revision,
            audio: audio,
            subtitle: subtitle,
          ),
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['schemaVersion'], 1);
      expect(body['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(body['expectedAccountRevision'], 1);
      expect(body['expectedRevision'], 7);
      expect(body['audioLanguage'], 'tr');
      expect(body['subtitleLanguage'], 'de');
      revision++;
      audio = body['audioLanguage'] as String?;
      subtitle = body['subtitleLanguage'] as String?;
      return fixture.json(
        _response(
          fixture,
          revision: revision,
          audio: audio,
          subtitle: subtitle,
        ),
      );
    };
    final migration = LegacyJellyfinTrackPreferencesMigration(
      core: JellyfinTrackPreferencesStore(account: fixture.account),
    );

    final receipt = await migration.prepare(_config, isCurrent: () => true);
    expect(receipt?.audioLanguage, 'tr');
    expect(receipt?.subtitleLanguage, isNull);
    expect(receipt.toString(), 'Legacy Jellyfin track preference migration');
    expect(receipt.toString(), isNot(contains(_config.baseUrl)));
    expect(receipt.toString(), isNot(contains(_config.userId)));
    expect(receipt.toString(), isNot(contains(_config.accessToken)));

    final saved = await migration.confirm(
      _config,
      receipt!,
      isCurrent: () => true,
    );

    expect(saved.audioLanguage, 'tr');
    expect(saved.subtitleLanguage, 'de');
    expect(
      (await SharedPreferences.getInstance()).containsKey(_legacyKey(_config)),
      isFalse,
    );
    final wire = fixture.calls
        .map((request) => '${request.url} ${request.body}')
        .join(' ');
    expect(wire, isNot(contains(_config.baseUrl)));
    expect(wire, isNot(contains(_config.userId)));
    expect(wire, isNot(contains(_config.accessToken)));
    expect(wire, isNot(contains(raw)));
  });

  test(
    'changed legacy source rejects stale confirmation before Core I/O',
    () async {
      SharedPreferences.setMockInitialValues({
        _legacyKey(_config): jsonEncode({
          'version': 1,
          'audio': 'en',
          'subtitle': null,
        }),
      });
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final migration = LegacyJellyfinTrackPreferencesMigration(
        core: JellyfinTrackPreferencesStore(account: fixture.account),
      );
      final receipt = await migration.prepare(_config, isCurrent: () => true);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _legacyKey(_config),
        jsonEncode({'version': 1, 'audio': 'fr', 'subtitle': null}),
      );

      await expectLater(
        migration.confirm(_config, receipt!, isCurrent: () => true),
        throwsStateError,
      );

      expect(
        fixture.calls.where(
          (request) =>
              request.url.path.contains('/media/language-preferences/'),
        ),
        isEmpty,
      );
      expect(preferences.containsKey(_legacyKey(_config)), isTrue);
    },
  );

  test('authority loss after Core commit keeps source and retry does not replay PUT', () async {
    SharedPreferences.setMockInitialValues({
      _legacyKey(_config): jsonEncode({
        'version': 1,
        'audio': 'tr',
        'subtitle': 'off',
      }),
    });
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    var revision = 0;
    String? audio;
    String? subtitle;
    var current = true;
    var putCount = 0;
    fixture.respond = (request) async {
      if (!request.url.path.contains('/media/language-preferences/')) {
        return fixture.defaultResponse(request);
      }
      if (request.method == 'GET') {
        return fixture.json(
          _response(
            fixture,
            revision: revision,
            audio: audio,
            subtitle: subtitle,
          ),
        );
      }
      putCount++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      revision++;
      audio = body['audioLanguage'] as String?;
      subtitle = body['subtitleLanguage'] as String?;
      current = false;
      return fixture.json(
        _response(
          fixture,
          revision: revision,
          audio: audio,
          subtitle: subtitle,
        ),
      );
    };
    final migration = LegacyJellyfinTrackPreferencesMigration(
      core: JellyfinTrackPreferencesStore(account: fixture.account),
    );
    final receipt = await migration.prepare(_config, isCurrent: () => current);

    await expectLater(
      migration.confirm(_config, receipt!, isCurrent: () => current),
      throwsStateError,
    );
    expect(putCount, 1);
    expect(
      (await SharedPreferences.getInstance()).containsKey(_legacyKey(_config)),
      isTrue,
    );

    current = true;
    final saved = await migration.confirm(
      _config,
      receipt,
      isCurrent: () => current,
    );

    expect(saved.audioLanguage, 'tr');
    expect(saved.subtitleLanguage, 'off');
    expect(putCount, 1, reason: 'the confirmed Core write must not replay');
    expect(
      (await SharedPreferences.getInstance()).containsKey(_legacyKey(_config)),
      isFalse,
    );
  });
}
