import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
    'preferenceRevision': revision ?? 0,
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
            'kind': 'media_language_preferences',
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
        if (request.url.path.contains('/media/language-preferences/')) {
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
          expect(body['expectedAccountRevision'], 1);
          expect(body['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
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
      await store.saveAudio(_direct, language: 'tr-TR', isCurrent: () => true);
      await store.saveSubtitle(_direct, language: 'off', isCurrent: () => true);
      final saved = await store.read(_direct, isCurrent: () => true);

      expect(saved?.audioLanguage, 'tr-tr');
      expect(saved?.subtitleLanguage, 'off');
      final wire = fixture.calls
          .where(
            (request) =>
                request.url.path.contains('/media/language-preferences/'),
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
      if (request.url.path.contains('/media/language-preferences/')) {
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

  test(
    'field edits preserve same-account sibling changes after stale reads',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      var revision = 1;
      var audio = 'en';
      var subtitle = 'off';
      fixture.respond = (request) async {
        if (request.url.path.contains('/media/language-preferences/')) {
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
          expect(body['expectedAccountRevision'], 1);
          expect(body['requestId'], matches(RegExp(r'^[0-9a-f]{32}$')));
          if (revision == 2) {
            expect(body['expectedRevision'], 2);
            expect(body['audioLanguage'], 'fr');
            expect(body['subtitleLanguage'], 'tr');
          } else {
            expect(revision, 4);
            expect(body['expectedRevision'], 4);
            expect(body['audioLanguage'], 'de');
            expect(body['subtitleLanguage'], 'off');
          }
          revision++;
          audio = body['audioLanguage'] as String;
          subtitle = body['subtitleLanguage'] as String;
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

      final stale = await store.read(_direct, isCurrent: () => true);
      expect(stale?.subtitleLanguage, 'off');
      revision = 2;
      subtitle = 'tr';

      final saved = await store.saveAudio(
        _direct,
        language: 'fr',
        isCurrent: () => true,
      );

      expect(saved.audioLanguage, 'fr');
      expect(saved.subtitleLanguage, 'tr');

      revision = 4;
      audio = 'de';
      final savedSubtitle = await store.saveSubtitle(
        _direct,
        language: 'off',
        isCurrent: () => true,
      );

      expect(savedSubtitle.audioLanguage, 'de');
      expect(savedSubtitle.subtitleLanguage, 'off');
    },
  );

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
      store.saveAudio(_direct, language: 'en', isCurrent: () => false),
      throwsStateError,
    );
    expect(
      fixture.calls.where(
        (request) => request.url.path.contains('/media/language-preferences/'),
      ),
      isEmpty,
    );
  });

  test(
    'retiring while Core read is pending prevents the preference write',
    () async {
      final fixture = AdminFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final read = Completer<http.Response>();
      var current = true;
      fixture.respond = (request) {
        if (request.url.path.contains('/media/language-preferences/')) {
          expect(request.method, 'GET');
          return read.future;
        }
        return Future.value(fixture.defaultResponse(request));
      };
      final store = JellyfinTrackPreferencesStore(account: fixture.account);

      final saving = store.saveAudio(
        _direct,
        language: 'en',
        isCurrent: () => current,
      );
      while (!fixture.calls.any(
        (request) => request.url.path.contains('/media/language-preferences/'),
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      read.complete(fixture.json(_response(fixture)));

      await expectLater(saving, throwsStateError);
      expect(
        fixture.calls.where(
          (request) =>
              request.url.path.contains('/media/language-preferences/'),
        ),
        hasLength(1),
      );
    },
  );
}
