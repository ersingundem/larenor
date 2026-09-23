import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_track_preferences_store.dart';

import '../../server/server_admin_test_support.dart';

const _direct = JellyfinConfig(
  baseUrl: 'https://direct-jellyfin.example.test',
  userId: 'direct-user',
  accessToken: 'must-not-leave-device',
  deviceId: 'direct-device',
);

Map<String, dynamic> _response(
  AdminFixture fixture, {
  int? revision,
  String? audio,
  String? subtitle,
  String? accountId,
}) => {
  'schemaVersion': 1,
  'authority': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'accountId': accountId ?? fixture.user.id,
    'accountRevision': 1,
    'sessionFamilyId': 'c' * 32,
  },
  'preference': revision == null
      ? null
      : {
          'schemaVersion': 1,
          'ref': {
            'schemaVersion': 1,
            'coreId': 'a' * 32,
            'homeId': 'b' * 32,
            'accountId': accountId ?? fixture.user.id,
            'kind': 'jellyfin_track_preferences',
          },
          'revision': revision,
          'audioLanguage': audio,
          'subtitleLanguage': subtitle,
        },
};

void main() {
  test(
    'player preferences use only the current Core account contract',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      var revision = 0;
      String? audio, subtitle;
      fixture.respond = (request) async {
        if (request.url.path.contains('/media/jellyfin/preferences/')) {
          if (request.method == 'GET') {
            return fixture.json(
              _response(
                fixture,
                revision: revision == 0 ? null : revision,
                audio: audio,
                subtitle: subtitle,
              ),
            );
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['expectedRevision'], revision);
          audio = body['audioLanguage'] as String?;
          subtitle = body['subtitleLanguage'] as String?;
          revision++;
          return fixture.json(
            _response(
              fixture,
              revision: revision,
              audio: audio,
              subtitle: subtitle,
            ),
          );
        }
        return fixture.defaultResponse(request);
      };
      final store = JellyfinTrackPreferencesStore(account: fixture.account);

      expect(await store.read(_direct, isCurrent: () => true), isNull);
      await store.save(
        _direct,
        audioLanguage: 'tr-TR',
        subtitleLanguage: 'off',
        isCurrent: () => true,
      );
      final saved = await store.read(_direct, isCurrent: () => true);

      expect(saved?.audioLanguage, 'tr-tr');
      expect(saved?.subtitleLanguage, 'off');
      final wire = fixture.calls
          .where(
            (request) =>
                request.url.path.contains('/media/jellyfin/preferences/'),
          )
          .map((request) => '${request.url} ${request.body}')
          .join(' ');
      expect(wire, isNot(contains(_direct.baseUrl)));
      expect(wire, isNot(contains(_direct.userId)));
      expect(wire, isNot(contains(_direct.accessToken)));
      expect(wire, contains('${'a' * 32}/${'b' * 32}'));
    },
  );

  test('mismatched Core account authority is rejected', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    fixture.respond = (request) async {
      if (request.url.path.contains('/media/jellyfin/preferences/')) {
        return fixture.json(
          _response(fixture, revision: 1, audio: 'en', accountId: 'f' * 32),
        );
      }
      return fixture.defaultResponse(request);
    };
    final store = JellyfinTrackPreferencesStore(account: fixture.account);

    await expectLater(
      store.read(_direct, isCurrent: () => true),
      throwsA(isA<Exception>()),
    );
  });

  test('retired player route cannot read or mutate Core preferences', () async {
    final fixture = AdminFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final store = JellyfinTrackPreferencesStore(account: fixture.account);

    await expectLater(
      store.read(_direct, isCurrent: () => false),
      throwsStateError,
    );
    await expectLater(
      store.save(
        _direct,
        audioLanguage: 'en',
        subtitleLanguage: null,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(
      fixture.calls.where(
        (request) => request.url.path.contains('/media/jellyfin/preferences/'),
      ),
      isEmpty,
    );
  });
}
